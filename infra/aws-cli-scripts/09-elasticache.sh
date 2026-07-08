#!/usr/bin/env bash
# Session 09 — ElastiCache Redis: single-node cluster in the private subnets, restricted to
# chatapp-ecs-sg via the chatapp-cache-sg security group session 07 already created for this.
#
# cache.t3.micro (smallest burstable node type ElastiCache offers) — deliberate cost control,
# same tone as session 07's single-NAT-Gateway tradeoff (docs/sessions/07-aws-networking-ecr.md).
# Single node, no replication group / Multi-AZ — this is a rate-limit counter + refresh-token
# blacklist, not data we need HA for; losing it just means users get logged out / rate limits
# reset, not data loss. Revisit if that judgment call stops holding.
#
# ElastiCache (VPC, non-Classic) requires a "cache subnet group" spanning the target subnets,
# same idea as an RDS subnet group. Created here, spanning both private subnets so an AZ failure
# doesn't strand it (even though the cluster itself is single-node/single-AZ).
#
# Idempotent: describe-before-create for both the subnet group and the cluster.
#
# Requires: 01-vpc.sh, 02-security-groups.sh already run (PRIVATE_SUBNET_A_ID/B_ID, CACHE_SG_ID).
# `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export MSYS_NO_PATHCONV=1

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
CACHE_CLUSTER_ID="${PROJECT_NAME}-redis"
CACHE_SUBNET_GROUP_NAME="${PROJECT_NAME}-cache-subnet-group"
CACHE_NODE_TYPE="cache.t3.micro"
REDIS_ENGINE_VERSION="7.1"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in PRIVATE_SUBNET_A_ID PRIVATE_SUBNET_B_ID CACHE_SG_ID; do
  if [ -z "${!v:-}" ]; then
    echo "$v not found in $ENV_FILE — run 01-vpc.sh / 02-security-groups.sh first." >&2
    exit 1
  fi
done

# --- Cache subnet group -------------------------------------------------------------------------

echo "== Cache subnet group: $CACHE_SUBNET_GROUP_NAME =="
if aws elasticache describe-cache-subnet-groups --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" \
    >/dev/null 2>&1; then
  echo "Subnet group already exists."
else
  aws elasticache create-cache-subnet-group \
    --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" \
    --cache-subnet-group-description "Private subnets for ${PROJECT_NAME} ElastiCache" \
    --subnet-ids "$PRIVATE_SUBNET_A_ID" "$PRIVATE_SUBNET_B_ID" >/dev/null
  echo "Created subnet group."
fi

# --- Cache cluster -------------------------------------------------------------------------------

echo
echo "== Cache cluster: $CACHE_CLUSTER_ID =="
EXISTING_STATUS="$(aws elasticache describe-cache-clusters --cache-cluster-id "$CACHE_CLUSTER_ID" \
  --query "CacheClusters[0].CacheClusterStatus" --output text 2>/dev/null || true)"

if [ -n "$EXISTING_STATUS" ] && [ "$EXISTING_STATUS" != "None" ]; then
  echo "Cluster already exists (status: $EXISTING_STATUS)."
else
  aws elasticache create-cache-cluster \
    --cache-cluster-id "$CACHE_CLUSTER_ID" \
    --engine redis \
    --engine-version "$REDIS_ENGINE_VERSION" \
    --cache-node-type "$CACHE_NODE_TYPE" \
    --num-cache-nodes 1 \
    --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" \
    --security-group-ids "$CACHE_SG_ID" \
    --port 6379 >/dev/null
  echo "Create requested, waiting for it to become available (a few minutes)..."
fi

aws elasticache wait cache-cluster-available --cache-cluster-id "$CACHE_CLUSTER_ID"
echo "Cluster available."

REDIS_ENDPOINT_ADDRESS="$(aws elasticache describe-cache-clusters --cache-cluster-id "$CACHE_CLUSTER_ID" \
  --show-cache-node-info --query "CacheClusters[0].CacheNodes[0].Endpoint.Address" --output text)"
REDIS_ENDPOINT_PORT="$(aws elasticache describe-cache-clusters --cache-cluster-id "$CACHE_CLUSTER_ID" \
  --show-cache-node-info --query "CacheClusters[0].CacheNodes[0].Endpoint.Port" --output text)"
REDIS_URL="redis://${REDIS_ENDPOINT_ADDRESS}:${REDIS_ENDPOINT_PORT}/0"

echo
echo "Endpoint: ${REDIS_ENDPOINT_ADDRESS}:${REDIS_ENDPOINT_PORT}"
echo "REDIS_URL: $REDIS_URL"

{
  grep -v -E "^(CACHE_CLUSTER_ID|CACHE_SUBNET_GROUP_NAME|REDIS_ENDPOINT_ADDRESS|REDIS_ENDPOINT_PORT|REDIS_URL)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
CACHE_CLUSTER_ID=$CACHE_CLUSTER_ID
CACHE_SUBNET_GROUP_NAME=$CACHE_SUBNET_GROUP_NAME
REDIS_ENDPOINT_ADDRESS=$REDIS_ENDPOINT_ADDRESS
REDIS_ENDPOINT_PORT=$REDIS_ENDPOINT_PORT
REDIS_URL=$REDIS_URL
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. Next: 09b-redis-deploy.sh to wire REDIS_URL into the backend and redeploy. =="
