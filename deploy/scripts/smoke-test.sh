#!/usr/bin/env bash
# Post-deploy smoke test: the right build is live and the app can talk to DynamoDB.
# Usage: smoke-test.sh <base-url> <expected-image-tag>
set -euo pipefail

URL="${1:?base url required}"
EXPECTED_TAG="${2:?expected image tag required}"

retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    [[ $n -ge 12 ]] && return 1
    echo "  retry $n/12 ..."
    sleep 5
  done
}

echo "1/5 liveness"
retry curl -fsS "${URL}/healthz" >/dev/null

echo "2/5 readiness (DynamoDB reachable via node IAM role)"
retry curl -fsS "${URL}/readyz" >/dev/null

echo "3/5 running the build we just shipped"
TAG=$(curl -fsS "${URL}/api/info" | jq -r .image_tag)
if [[ "$TAG" != "$EXPECTED_TAG" ]]; then
  echo "##vso[task.logissue type=error]Expected image ${EXPECTED_TAG} but ${URL} reports ${TAG}"
  exit 1
fi

echo "4/5 dashboard served"
curl -fsS "${URL}/" | grep -q "<title>CloudPulse</title>"

echo "5/5 write path: create + delete a monitor"
ID=$(curl -fsS -X POST "${URL}/api/monitors" -H 'Content-Type: application/json' \
  -d '{"name":"smoke-test","url":"https://example.com"}' | jq -r .id)
curl -fsS -X DELETE "${URL}/api/monitors/${ID}" -o /dev/null

echo "Smoke test passed for ${URL} (${TAG})"
