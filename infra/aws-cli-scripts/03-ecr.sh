#!/usr/bin/env bash
# Session 07 — ECR repositories: one each for frontend, backend, grafana.
#
# Idempotent: describe-repositories before create.
#
# Requires: `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"

create_repo() {
  local name="$1"
  local uri
  uri="$(aws ecr describe-repositories --repository-names "$name" \
    --query "repositories[0].repositoryUri" --output text 2>/dev/null || true)"
  if [ -z "${uri:-}" ] || [ "$uri" = "None" ]; then
    uri="$(aws ecr create-repository --repository-name "$name" \
      --image-scanning-configuration scanOnPush=true \
      --query "repository.repositoryUri" --output text)"
    echo "Created ECR repo $name: $uri" >&2
  else
    echo "ECR repo $name already exists: $uri" >&2
  fi
  echo "$uri"
}

echo "== ECR repositories =="
ECR_FRONTEND_URI="$(create_repo "${PROJECT_NAME}-frontend")"
ECR_BACKEND_URI="$(create_repo "${PROJECT_NAME}-backend")"
ECR_GRAFANA_URI="$(create_repo "${PROJECT_NAME}-grafana")"

{
  grep -v -E "^(ECR_FRONTEND_URI|ECR_BACKEND_URI|ECR_GRAFANA_URI)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
ECR_FRONTEND_URI=$ECR_FRONTEND_URI
ECR_BACKEND_URI=$ECR_BACKEND_URI
ECR_GRAFANA_URI=$ECR_GRAFANA_URI
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. =="
