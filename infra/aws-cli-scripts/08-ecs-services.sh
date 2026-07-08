#!/usr/bin/env bash
# Session 08 — ECS services: ties the task definitions to the ALB target groups, running in the
# private subnets (egress via session 07's NAT Gateway; not directly internet-reachable — only
# the ALB is public). Desired count 1 each to start (matches the brief; scaling is a later
# concern).
#
# Idempotent: describe-services + create-or-update pattern.
#
# Requires: 05-ecs-cluster.sh, 06-alb.sh, 07-task-defs.sh already run, and the images for
# IMAGE_TAG already pushed to ECR (this script does not build/push images itself).
# `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export MSYS_NO_PATHCONV=1

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in CLUSTER_NAME PRIVATE_SUBNET_A_ID PRIVATE_SUBNET_B_ID ECS_SG_ID \
         FRONTEND_TG_ARN BACKEND_TG_ARN BACKEND_TASK_DEF_ARN FRONTEND_TASK_DEF_ARN; do
  if [ -z "${!v:-}" ]; then
    echo "$v not found in $ENV_FILE — run earlier scripts first." >&2
    exit 1
  fi
done

NETWORK_CONFIG="{\"awsvpcConfiguration\":{\"subnets\":[\"$PRIVATE_SUBNET_A_ID\",\"$PRIVATE_SUBNET_B_ID\"],\"securityGroups\":[\"$ECS_SG_ID\"],\"assignPublicIp\":\"DISABLED\"}}"

# Production-audit follow-up: circuit breaker + auto-rollback. Without this, a deploy that pushes
# a task which never reaches a healthy state (crashes on startup, fails its ALB health check,
# etc.) just sits there indefinitely instead of automatically reverting to the last known-good
# task definition — confirmed this was actually off on the live services
# (`deploymentCircuitBreaker.enable: false`) before this fix, not assumed.
DEPLOYMENT_CONFIG='deploymentCircuitBreaker={enable=true,rollback=true}'

create_or_update_service() {
  local name="$1" task_def_arn="$2" tg_arn="$3" container_name="$4" container_port="$5"
  local status
  status="$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$name" \
    --query "services[0].status" --output text 2>/dev/null || true)"
  if [ "$status" = "ACTIVE" ]; then
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$name" \
      --task-definition "$task_def_arn" --force-new-deployment \
      --deployment-configuration "$DEPLOYMENT_CONFIG" >/dev/null
    echo "Updated existing service $name to $task_def_arn."
  else
    aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$name" \
      --task-definition "$task_def_arn" --desired-count 1 --launch-type FARGATE \
      --network-configuration "$NETWORK_CONFIG" \
      --load-balancers "targetGroupArn=$tg_arn,containerName=$container_name,containerPort=$container_port" \
      --health-check-grace-period-seconds 60 \
      --deployment-configuration "$DEPLOYMENT_CONFIG" >/dev/null
    echo "Created service $name."
  fi
}

echo "== Backend service =="
create_or_update_service "${PROJECT_NAME}-backend" "$BACKEND_TASK_DEF_ARN" "$BACKEND_TG_ARN" "backend" 8000

echo
echo "== Frontend service =="
create_or_update_service "${PROJECT_NAME}-frontend" "$FRONTEND_TASK_DEF_ARN" "$FRONTEND_TG_ARN" "frontend" 3000

echo
echo "== Waiting for services to reach steady state (this can take a few minutes) =="
aws ecs wait services-stable --cluster "$CLUSTER_NAME" \
  --services "${PROJECT_NAME}-backend" "${PROJECT_NAME}-frontend"
echo "Both services stable."

echo
echo "== Done. App should be live at http://${ALB_DNS_NAME} =="
