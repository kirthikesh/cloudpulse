# Setup guide: AWS + Azure DevOps

Follow this top to bottom. It takes about 45 minutes the first time.

## 0. Prerequisites

- AWS account, with the AWS CLI configured locally as an admin user (`aws sts get-caller-identity` works)
- Terraform **1.10+** (`brew install terraform`)
- An Azure DevOps organisation (free): https://dev.azure.com
- This repo on GitHub: `kirthikesh/cloudpulse`

> **Azure DevOps parallel jobs:** new organisations get **no** free Microsoft-hosted minutes until you request them. Use the free-tier request form (*Organization settings → Parallel jobs*); approval can take a few days. Until then you can run a **self-hosted agent** on your Mac (*Project settings → Agent pools → Default → New agent*) and change `pool:` in the pipelines to `name: Default`.

## 1. Terraform state bucket (one time)

```bash
cd infra/bootstrap
terraform init
terraform apply
# note the output: state_bucket = "cloudpulse-tfstate-<ACCOUNT_ID>"
```

## 2. Build the AWS infrastructure

The first apply runs from your laptop, because the infra pipeline needs an AWS identity that can create IAM resources.

```bash
cd infra/aws
cp terraform.tfvars.example terraform.tfvars    # optional: set alert_email, lock allowed_http_cidrs
terraform init -backend-config="bucket=cloudpulse-tfstate-<ACCOUNT_ID>"
terraform apply
```

Outputs to keep:

```
node_public_ip         = "x.x.x.x"
dashboard_urls         = { dev = "http://dev.x.x.x.x.nip.io", prod = "http://prod.x.x.x.x.nip.io" }
azure_devops_iam_user  = "cloudpulse-azure-devops"
ssm_shell              = "aws ssm start-session --target i-..."
```

The node bootstraps k3s itself, which takes about 3 minutes. To check it:

```bash
aws ssm start-session --target <instance-id> --region eu-west-1
sudo cat /var/log/cloudpulse-bootstrap.log | tail
sudo kubectl get nodes
```

Commit the generated `infra/aws/.terraform.lock.hcl` so the pipeline uses the same provider versions.

## 3. Access key for the pipeline

AWS Console → IAM → Users → **cloudpulse-azure-devops** → Security credentials → **Create access key** (use case: *Third-party service*). Copy the key ID and secret. You'll paste them into Azure DevOps in the next step and nowhere else.

## 4. Azure DevOps

1. **Install the AWS extension.** Marketplace → *AWS Toolkit for Azure DevOps* → install in your org. This adds the `AWSShellScript@1` task and the AWS service connection type.
2. **Create a project** called `cloudpulse`.
3. **AWS service connection.** *Project settings → Service connections → New → AWS*
   - Access Key ID / Secret: from step 3
   - Name: **`aws-cloudpulse`** (it must match `awsConnection` in the pipeline)
4. **GitHub connection.** When you create the pipeline, pick GitHub, then authorise the Azure Pipelines app on `kirthikesh/cloudpulse`.
5. **Environments.** *Pipelines → Environments → New*:
   - `cloudpulse-dev` (no checks)
   - `cloudpulse-prod`: open it → ⋮ → *Approvals and checks* → **Approvals** → add yourself
6. **Pipeline.** *Pipelines → New → GitHub → kirthikesh/cloudpulse → Existing YAML* → `/pipelines/app-pipeline.yml` → Run.

What you should see:

```
CI ── Lint + unit tests ── Build, scan, push
 └─ Deploy dev ── Helm upgrade via SSM ── Smoke test dev
     └─ [waiting for approval]
         └─ Deploy prod ── Helm upgrade via SSM ── Smoke test prod
```

Open `http://dev.<ip>.nip.io`, approve prod, then open `http://prod.<ip>.nip.io`. The **Ops** tab shows the build ID and image tag that just shipped.

## 5. (Optional) Infra pipeline

For Terraform changes through Azure DevOps instead of your laptop:

1. Create a second IAM user (e.g. `cloudpulse-terraform`) with permissions for VPC/EC2/ECR/DynamoDB/IAM/CloudWatch/SNS and the state bucket. For a personal account, `PowerUserAccess` + `IAMFullAccess` is the pragmatic option.
2. Service connection **`aws-cloudpulse-infra`** with that user's key.
3. Environment **`cloudpulse-infra`** with an Approval check.
4. New pipeline from `/pipelines/infra-pipeline.yml`, and add a pipeline variable `TF_STATE_BUCKET = cloudpulse-tfstate-<ACCOUNT_ID>`.

PRs that touch `infra/aws` run fmt, validate, Checkov and plan. On `main`, apply waits for your approval. Read `plan.txt` in the run's artifacts before approving.

## 6. Day-2 commands

```bash
# shell on the node (no SSH)
aws ssm start-session --target <instance-id>

sudo kubectl -n prod get pods,hpa,ingress
sudo helm -n prod history cloudpulse
sudo helm -n prod rollback cloudpulse <revision>   # manual rollback
```

## 7. Tear down (stop paying)

```bash
cd infra/aws && terraform destroy
```

This removes everything except the state bucket (≈ $0). Run `terraform apply` again later to rebuild, then re-run the pipeline.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No running k3s node found` | Infra not applied, or the instance is stopped |
| SSM step says `node bootstrap not finished yet` | Wait 3 minutes after the first apply and re-run the stage |
| Pods stuck in `ImagePullBackOff` | `sudo /usr/local/bin/ecr-refresh.sh` on the node |
| `/readyz` returns 503 | Pod can't reach DynamoDB. Check the instance role and that the table `cloudpulse-<env>` exists |
| Trivy fails the build | Bump the base image (`python:3.12-slim`) or the pinned package that has the CVE |
| `terraform fmt` fails in the pipeline | Run `terraform fmt -recursive infra` locally and commit |
