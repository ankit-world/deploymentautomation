#!/usr/bin/env bash
# Session 07 — Security groups: ALB (public), ECS tasks (only from ALB), ElastiCache (only from
# ECS tasks). No SG here allows ElastiCache/ECS to be reached directly from the internet.
#
# Idempotent: looks up each SG by Name tag first, only creates if missing. Ingress rules use
# authorize-security-group-ingress with --output-based existence checks so re-running doesn't
# error on "rule already exists".
#
# Requires: 01-vpc.sh already run (sources VPC_ID from .env.aws). `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -z "${VPC_ID:-}" ]; then
  echo "VPC_ID not found in $ENV_FILE — run 01-vpc.sh first." >&2
  exit 1
fi

get_sg() {
  aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v '^None$' || true
}

create_sg() {
  local name="$1" desc="$2"
  local id
  id="$(get_sg "$name")"
  if [ -z "${id:-}" ]; then
    id="$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$name}]" \
      --query "GroupId" --output text)"
    echo "Created SG $name: $id" >&2
  else
    echo "SG $name already exists: $id" >&2
  fi
  echo "$id"
}

# authorize_ingress <sg-id> <protocol> <port> <source-sg-id-or-cidr> [cidr|sg]
# Idempotent via "attempt and tolerate InvalidPermission.Duplicate" rather than a pre-check —
# JMESPath filtering on nested IpPermissions/IpRanges projections is unreliable for this shape of
# query, and the AWS API already tells us unambiguously whether the rule exists.
authorize_ingress() {
  local sg="$1" proto="$2" port="$3" source="$4" kind="$5"
  local flag output
  if [ "$kind" = "cidr" ]; then
    flag="--cidr"
  else
    flag="--source-group"
  fi
  set +e
  output="$(aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol "$proto" \
    --port "$port" "$flag" "$source" 2>&1)"
  local status=$?
  set -e
  if [ $status -eq 0 ]; then
    echo "  Authorized $proto/$port from $source on $sg."
  elif echo "$output" | grep -q "InvalidPermission.Duplicate"; then
    echo "  Ingress $proto/$port from $source already present on $sg, skipping."
  else
    echo "$output" >&2
    return 1
  fi
}

echo "== ALB security group =="
ALB_SG_ID="$(create_sg "${PROJECT_NAME}-alb-sg" "ALB: public HTTP/HTTPS ingress")"
authorize_ingress "$ALB_SG_ID" tcp 80 "0.0.0.0/0" cidr
authorize_ingress "$ALB_SG_ID" tcp 443 "0.0.0.0/0" cidr

echo
echo "== ECS tasks security group =="
ECS_SG_ID="$(create_sg "${PROJECT_NAME}-ecs-sg" "ECS tasks: ingress only from the ALB")"
# Frontend (3000), backend (8000), grafana (3000 too internally is fine, distinct container) —
# session 08 assigns exact container ports; opening the app port range from the ALB SG only.
authorize_ingress "$ECS_SG_ID" tcp 3000 "$ALB_SG_ID" sg
authorize_ingress "$ECS_SG_ID" tcp 8000 "$ALB_SG_ID" sg

echo
echo "== ElastiCache security group =="
CACHE_SG_ID="$(create_sg "${PROJECT_NAME}-cache-sg" "ElastiCache: ingress only from ECS tasks")"
authorize_ingress "$CACHE_SG_ID" tcp 6379 "$ECS_SG_ID" sg

{
  grep -v -E "^(ALB_SG_ID|ECS_SG_ID|CACHE_SG_ID)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
ALB_SG_ID=$ALB_SG_ID
ECS_SG_ID=$ECS_SG_ID
CACHE_SG_ID=$CACHE_SG_ID
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. =="
