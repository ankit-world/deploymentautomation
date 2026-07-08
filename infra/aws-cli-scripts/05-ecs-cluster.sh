#!/usr/bin/env bash
# Session 08 — ECS Fargate cluster. Container Insights is deliberately NOT enabled here — that's
# session 09's job (docs/sessions/09-elasticache-cloudwatch.md), not this one.
#
# Idempotent: describe-clusters before create.
#
# Requires: `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
CLUSTER_NAME="${PROJECT_NAME}-cluster"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"

echo "== ECS cluster: $CLUSTER_NAME =="
STATUS="$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
  --query "clusters[0].status" --output text 2>/dev/null || true)"
if [ "$STATUS" = "ACTIVE" ]; then
  echo "Cluster already exists and is ACTIVE."
else
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null
  echo "Created cluster."
fi

{
  grep -v -E "^CLUSTER_NAME=" "$ENV_FILE" 2>/dev/null || true
  echo "CLUSTER_NAME=$CLUSTER_NAME"
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. =="
