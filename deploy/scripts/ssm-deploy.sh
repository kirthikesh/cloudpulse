#!/usr/bin/env bash
# Deploys a CloudPulse release to the k3s node through AWS SSM Run Command.
# Runs on the Azure DevOps agent (inside AWSShellScript, so AWS creds are already set).
#
# No SSH keys, no open k8s API: the node's SSM agent pulls the command from AWS,
# runs `helm upgrade` locally, and the result is polled here.
#
# Usage: ssm-deploy.sh <env> <image-tag> <chart-version>
set -euo pipefail

ENV_NAME="${1:?env (dev|prod) required}"
IMAGE_TAG="${2:?image tag required}"
CHART_VERSION="${3:?chart version required}"
REGION="${AWS_REGION:-eu-west-1}"
PROJECT="${PROJECT:-cloudpulse}"
BUILD_ID="${BUILD_BUILDID:-manual}"
GIT_SHA="${BUILD_SOURCEVERSION:-unknown}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Find the node by tag instead of hard-coding an instance id
read -r INSTANCE_ID PUBLIC_IP < <(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=${PROJECT}" "Name=tag:Role,Values=k3s-node" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]' --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "##vso[task.logissue type=error]No running k3s node found (tag Project=${PROJECT}, Role=k3s-node). Run the infra pipeline first."
  exit 1
fi

HOST="${ENV_NAME}.${PUBLIC_IP}.nip.io"
echo "Deploying ${IMAGE_TAG} (chart ${CHART_VERSION}) to ${ENV_NAME} on ${INSTANCE_ID} -> http://${HOST}"

# Script executed ON the node (as root, by the SSM agent)
REMOTE_SCRIPT=$(cat <<EOF
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
test -f /var/lib/cloudpulse-bootstrap-done || { echo "node bootstrap not finished yet"; exit 1; }
/usr/local/bin/ecr-refresh.sh
aws ecr get-login-password --region ${REGION} | helm registry login ${REGISTRY} --username AWS --password-stdin
WORK=\$(mktemp -d)
helm pull oci://${REGISTRY}/charts/${PROJECT} --version ${CHART_VERSION} --untar --untardir "\$WORK"
helm upgrade --install ${PROJECT} "\$WORK/${PROJECT}" \
  --namespace ${ENV_NAME} \
  -f "\$WORK/${PROJECT}/values-${ENV_NAME}.yaml" \
  --set image.repository=${REGISTRY}/${PROJECT} \
  --set-string image.tag=${IMAGE_TAG} \
  --set-string build.id=${BUILD_ID} \
  --set-string build.gitSha=${GIT_SHA} \
  --set aws.region=${REGION} \
  --set aws.tableName=${PROJECT}-${ENV_NAME} \
  --set ingress.host=${HOST} \
  --atomic --wait --timeout 5m
rm -rf "\$WORK"
kubectl -n ${ENV_NAME} get pods -o wide
helm -n ${ENV_NAME} history ${PROJECT} --max 5
EOF
)

PARAMS=$(jq -n --arg s "$REMOTE_SCRIPT" '{commands: [$s], executionTimeout: ["600"]}')

COMMAND_ID=$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "cloudpulse ${ENV_NAME} ${IMAGE_TAG} (ADO build ${BUILD_ID})" \
  --parameters "$PARAMS" \
  --query 'Command.CommandId' --output text)

echo "SSM command: ${COMMAND_ID}"

# Poll until done (aws ssm wait gives up after ~100s, helm --wait can take longer)
STATUS="Pending"
for _ in $(seq 1 80); do
  sleep 5
  STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in Pending|InProgress|Delayed) continue ;; *) break ;; esac
done

echo "----- node output -----"
aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text
echo "----- node errors -----"
aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" --query StandardErrorContent --output text

if [[ "$STATUS" != "Success" ]]; then
  echo "##vso[task.logissue type=error]Deploy to ${ENV_NAME} failed with SSM status ${STATUS} (helm --atomic rolled back)"
  exit 1
fi

# Hand the URL to later steps (smoke test)
echo "##vso[task.setvariable variable=appUrl]http://${HOST}"
echo "##vso[task.setvariable variable=appUrl;isOutput=true]http://${HOST}"
echo "Deployed: http://${HOST}"
