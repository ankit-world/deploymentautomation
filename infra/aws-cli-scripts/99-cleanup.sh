#!/usr/bin/env bash
# Full teardown of everything 00-account-bootstrap.sh through 10-grafana-ecs.sh created, in
# reverse dependency order, to stop all billing for this project. Single consolidated script by
# design (not 14 reverse-numbered ones) - this only ever needs to be run as one atomic "tear it
# all down" operation, unlike the numbered setup scripts which are each a distinct, independently
# re-runnable concern.
#
# Resource identifiers are read from .env.aws (written by the setup scripts) - not hardcoded -
# so this always targets whatever actually got created on this account, not a guess.
#
# NOT deleted by default: the GitHub OIDC provider, the chatapp-github-deploy IAM role, and the
# monthly budget alarm (all from 00-account-bootstrap.sh). None of these bill anything - IAM and
# Budgets are free - and deleting the OIDC provider means re-running 00 later has to recompute a
# live TLS thumbprint and redo the trust policy by hand. Pass --include-account-bootstrap to also
# remove these for a truly from-scratch teardown (e.g. abandoning the project for good).
#
# Every AWS call below is wrapped so a resource that's already gone (partial prior teardown,
# manual deletion, never-created) doesn't stop the script - same tolerance the reference cleanup
# script this was adapted from uses, extended here to cover this project's actual resource set
# (S3, Secrets Manager, CloudWatch alarms/SNS - none of which the reference covered - plus the
# real names/ARNs this project's scripts produce, which differ from the reference's).
#
# Usage:
#   ./99-cleanup.sh --dry-run                    # print what would be deleted, delete nothing
#   ./99-cleanup.sh                               # interactive: type the project name to confirm
#   ./99-cleanup.sh --include-account-bootstrap   # also remove OIDC provider/deploy role/budget

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"

if [ ! -f "$ENV_FILE" ]; then
  echo "$ENV_FILE not found - nothing recorded as created. Nothing to clean up." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

DRY_RUN=false
INCLUDE_BOOTSTRAP=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --include-account-bootstrap) INCLUDE_BOOTSTRAP=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

# --- Identity check: refuse to run against the wrong account -----------------------------------

echo "== Verifying AWS identity =="
IDENTITY="$(aws sts get-caller-identity)"
echo "$IDENTITY"
if ! echo "$IDENTITY" | grep -q "\"Account\": \"${AWS_ACCOUNT_ID}\""; then
  echo "Refusing to continue: current identity is not account ${AWS_ACCOUNT_ID}." >&2
  exit 1
fi
echo

echo "========================================================================"
echo " This will DELETE the following, permanently, in AWS account ${AWS_ACCOUNT_ID}:"
echo "========================================================================"
echo "  ECS services/cluster:  ${CLUSTER_NAME:-<not recorded>} (backend, frontend, grafana)"
echo "  ALB:                   ${ALB_DNS_NAME:-<not recorded>}"
echo "  ElastiCache:            ${CACHE_CLUSTER_ID:-<not recorded>}"
echo "  ECR images/repos:      chatapp-backend, chatapp-frontend, chatapp-grafana"
echo "  Secrets Manager:       mongodb-uri, jwt-secret, openai-api-key, openai-base-url,"
echo "                          grafana-admin-password (immediate delete, no recovery window)"
echo "  S3 bucket + all files: ${S3_BUCKET:-<not recorded>}"
echo "  IAM roles:              chatapp-ecs-execution-role, chatapp-ecs-task-role,"
echo "                          chatapp-grafana-task-role"
echo "  CloudWatch:             7 alarms, SNS topic ${SNS_TOPIC_NAME:-chatapp-alerts}, 3 log groups"
echo "  Networking:             NAT gateway + EIP, security groups, subnets, route tables, IGW, VPC"
if [ "$INCLUDE_BOOTSTRAP" = true ]; then
  echo "  Account bootstrap:     GitHub OIDC provider, chatapp-github-deploy role, budget alarm"
else
  echo "  NOT deleted (free, kept by default): GitHub OIDC provider, chatapp-github-deploy role,"
  echo "                          budget alarm. Pass --include-account-bootstrap to remove these too."
fi
echo "========================================================================"
echo

if [ "$DRY_RUN" = true ]; then
  echo "--dry-run: nothing deleted."
  exit 0
fi

read -r -p "Type the project name (${PROJECT_NAME:-chatapp}) to confirm deletion: " CONFIRM
if [ "$CONFIRM" != "${PROJECT_NAME:-chatapp}" ]; then
  echo "Confirmation did not match. Aborted - nothing was deleted."
  exit 0
fi
echo

# Poll helper: run "$@" repeatedly until it exits non-zero (resource gone) or timeout.
wait_until_gone() {
  local desc="$1" max_wait="$2"; shift 2
  local waited=0
  while "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$max_wait" ]; then
      echo "  ... $desc still not gone after ${max_wait}s, continuing anyway."
      return 0
    fi
    echo "  ... waiting for $desc to finish deleting (${waited}s/${max_wait}s)"
    sleep 10
    waited=$((waited + 10))
  done
}

# --- 1. ECS services + cluster ------------------------------------------------------------------

echo "== ECS services =="
for svc in "${PROJECT_NAME}-backend" "${PROJECT_NAME}-frontend" "${PROJECT_NAME}-grafana"; do
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" --desired-count 0 >/dev/null 2>&1 || true
done
sleep 5
for svc in "${PROJECT_NAME}-backend" "${PROJECT_NAME}-frontend" "${PROJECT_NAME}-grafana"; do
  aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$svc" --force >/dev/null 2>&1 || true
  echo "  Deleted service $svc (or already gone)."
done

echo "== ECS task definitions (deregistering all revisions) =="
for family in "${PROJECT_NAME}-backend" "${PROJECT_NAME}-frontend" "${PROJECT_NAME}-grafana"; do
  for arn in $(aws ecs list-task-definitions --family-prefix "$family" --status ACTIVE --query "taskDefinitionArns[]" --output text 2>/dev/null || true); do
    aws ecs deregister-task-definition --task-definition "$arn" >/dev/null 2>&1 || true
  done
  echo "  Deregistered revisions for $family (or none found)."
done

echo "== ECS cluster =="
aws ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
echo "  Deleted cluster $CLUSTER_NAME (or already gone)."
echo

# --- 2. ALB: listener, load balancer, target groups ---------------------------------------------

echo "== ALB =="
if [ -n "${LISTENER_ARN:-}" ]; then
  aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" >/dev/null 2>&1 || true
fi
if [ -n "${ALB_ARN:-}" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" >/dev/null 2>&1 || true
  echo "  Deleted load balancer (or already gone). Waiting 20s before deleting target groups..."
  sleep 20
fi
for tg in "${BACKEND_TG_ARN:-}" "${FRONTEND_TG_ARN:-}" "${GRAFANA_TG_ARN:-}"; do
  [ -n "$tg" ] && aws elbv2 delete-target-group --target-group-arn "$tg" >/dev/null 2>&1 || true
done
echo "  Deleted target groups (or already gone)."
echo

# --- 3. CloudWatch: alarms, SNS topic, log groups ------------------------------------------------

echo "== CloudWatch alarms =="
ALARM_NAMES="$(aws cloudwatch describe-alarms --alarm-name-prefix "${PROJECT_NAME}-" --query "MetricAlarms[].AlarmName" --output text 2>/dev/null || true)"
if [ -n "$ALARM_NAMES" ]; then
  # shellcheck disable=SC2086
  aws cloudwatch delete-alarms --alarm-names $ALARM_NAMES >/dev/null 2>&1 || true
  echo "  Deleted alarms: $ALARM_NAMES"
else
  echo "  No alarms found."
fi

echo "== SNS topic =="
if [ -n "${SNS_TOPIC_ARN:-}" ]; then
  aws sns delete-topic --topic-arn "$SNS_TOPIC_ARN" >/dev/null 2>&1 || true
  echo "  Deleted topic ${SNS_TOPIC_NAME:-} (or already gone)."
fi

echo "== CloudWatch log groups =="
for lg in "/ecs/${PROJECT_NAME}-backend" "/ecs/${PROJECT_NAME}-frontend" "/ecs/${PROJECT_NAME}-grafana"; do
  aws logs delete-log-group --log-group-name "$lg" >/dev/null 2>&1 || true
  echo "  Deleted $lg (or already gone)."
done
echo

# --- 4. ElastiCache ------------------------------------------------------------------------------

echo "== ElastiCache =="
if [ -n "${CACHE_CLUSTER_ID:-}" ]; then
  aws elasticache delete-cache-cluster --cache-cluster-id "$CACHE_CLUSTER_ID" >/dev/null 2>&1 || true
  wait_until_gone "Redis cluster $CACHE_CLUSTER_ID" 300 \
    aws elasticache describe-cache-clusters --cache-cluster-id "$CACHE_CLUSTER_ID"
  echo "  Redis cluster deleted (or already gone)."
fi
if [ -n "${CACHE_SUBNET_GROUP_NAME:-}" ]; then
  aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" >/dev/null 2>&1 || true
  echo "  Deleted cache subnet group (or already gone)."
fi
echo

# --- 5. ECR repositories (force-deletes images too) -----------------------------------------------

echo "== ECR repositories =="
for repo in "${PROJECT_NAME}-backend" "${PROJECT_NAME}-frontend" "${PROJECT_NAME}-grafana"; do
  aws ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 || true
  echo "  Deleted repository $repo (or already gone)."
done
echo

# --- 6. Secrets Manager (immediate delete, no recovery window) -----------------------------------

echo "== Secrets Manager =="
for secret_arn in "${MONGODB_URI_ARN:-}" "${JWT_SECRET_ARN:-}" "${OPENAI_API_KEY_ARN:-}" \
                  "${OPENAI_BASE_URL_ARN:-}" "${GRAFANA_ADMIN_PASSWORD_ARN:-}"; do
  if [ -n "$secret_arn" ]; then
    aws secretsmanager delete-secret --secret-id "$secret_arn" --force-delete-without-recovery >/dev/null 2>&1 || true
  fi
done
echo "  Deleted secrets (or already gone)."
echo

# --- 7. S3 bucket (must be emptied before it can be deleted) -------------------------------------

echo "== S3 bucket =="
if [ -n "${S3_BUCKET:-}" ]; then
  aws s3 rm "s3://${S3_BUCKET}" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 || true
  echo "  Emptied and deleted bucket $S3_BUCKET (or already gone)."
fi
echo

# --- 8. IAM roles (must detach/delete all policies before the role itself) -----------------------

echo "== IAM roles =="

EXEC_ROLE_NAME="${PROJECT_NAME}-ecs-execution-role"
aws iam detach-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" >/dev/null 2>&1 || true
for pol in "chatapp-read-secrets" "chatapp-read-grafana-secret"; do
  aws iam delete-role-policy --role-name "$EXEC_ROLE_NAME" --policy-name "$pol" >/dev/null 2>&1 || true
done
aws iam delete-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1 || true
echo "  Deleted $EXEC_ROLE_NAME (or already gone)."

TASK_ROLE_NAME="${PROJECT_NAME}-ecs-task-role"
aws iam delete-role-policy --role-name "$TASK_ROLE_NAME" --policy-name "chatapp-s3-access" >/dev/null 2>&1 || true
aws iam delete-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1 || true
echo "  Deleted $TASK_ROLE_NAME (or already gone)."

GRAFANA_TASK_ROLE_NAME="${PROJECT_NAME}-grafana-task-role"
aws iam delete-role-policy --role-name "$GRAFANA_TASK_ROLE_NAME" --policy-name "chatapp-cloudwatch-read" >/dev/null 2>&1 || true
aws iam delete-role --role-name "$GRAFANA_TASK_ROLE_NAME" >/dev/null 2>&1 || true
echo "  Deleted $GRAFANA_TASK_ROLE_NAME (or already gone)."
echo

# --- 9. Networking: NAT gateway, EIP, security groups, subnets, route tables, IGW, VPC -----------

echo "== NAT Gateway =="
if [ -n "${NAT_GATEWAY_ID:-}" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GATEWAY_ID" >/dev/null 2>&1 || true
  wait_until_gone "NAT gateway $NAT_GATEWAY_ID" 300 bash -c \
    "[ \"\$(aws ec2 describe-nat-gateways --nat-gateway-ids '$NAT_GATEWAY_ID' --query 'NatGateways[0].State' --output text 2>/dev/null)\" != 'deleted' ]"
  echo "  NAT gateway deleted (or already gone)."
fi
if [ -n "${NAT_EIP_ALLOC_ID:-}" ]; then
  aws ec2 release-address --allocation-id "$NAT_EIP_ALLOC_ID" >/dev/null 2>&1 || true
  echo "  Released Elastic IP."
fi

echo "== Security groups =="
for sg in "${CACHE_SG_ID:-}" "${ECS_SG_ID:-}" "${ALB_SG_ID:-}"; do
  [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 || true
done
echo "  Deleted security groups (or already gone)."

echo "== Subnets (also removes their route-table associations) =="
for subnet in "${PUBLIC_SUBNET_A_ID:-}" "${PUBLIC_SUBNET_B_ID:-}" "${PRIVATE_SUBNET_A_ID:-}" "${PRIVATE_SUBNET_B_ID:-}"; do
  [ -n "$subnet" ] && aws ec2 delete-subnet --subnet-id "$subnet" >/dev/null 2>&1 || true
done
echo "  Deleted subnets (or already gone)."

echo "== Route tables =="
for rtb in "${PUBLIC_RTB_ID:-}" "${PRIVATE_RTB_ID:-}"; do
  [ -n "$rtb" ] && aws ec2 delete-route-table --route-table-id "$rtb" >/dev/null 2>&1 || true
done
echo "  Deleted route tables (or already gone)."

echo "== Internet Gateway =="
if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" >/dev/null 2>&1 || true
  echo "  Detached and deleted IGW (or already gone)."
fi

echo "== VPC =="
if [ -n "${VPC_ID:-}" ]; then
  aws ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
  echo "  Deleted VPC $VPC_ID (or already gone)."
fi
echo

# --- 10. Account bootstrap (opt-in only - free resources, kept by default) -----------------------

if [ "$INCLUDE_BOOTSTRAP" = true ]; then
  echo "== Account bootstrap (--include-account-bootstrap) =="
  aws iam delete-role-policy --role-name "${PROJECT_NAME}-github-deploy" --policy-name "chatapp-deploy-scope" >/dev/null 2>&1 || true
  aws iam delete-role --role-name "${PROJECT_NAME}-github-deploy" >/dev/null 2>&1 || true
  echo "  Deleted ${PROJECT_NAME}-github-deploy role (or already gone)."

  if [ -n "${OIDC_PROVIDER_ARN:-}" ]; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1 || true
    echo "  Deleted GitHub OIDC provider (or already gone)."
  fi

  aws budgets delete-budget --account-id "$AWS_ACCOUNT_ID" --budget-name "${PROJECT_NAME}-monthly" >/dev/null 2>&1 || true
  echo "  Deleted budget alarm (or already gone)."
  echo
fi

echo "========================================================================"
echo " Cleanup complete."
echo "========================================================================"
if [ "$INCLUDE_BOOTSTRAP" = false ]; then
  echo "Kept (free, not billed): GitHub OIDC provider, ${PROJECT_NAME}-github-deploy role, budget alarm."
  echo "Re-run with --include-account-bootstrap to remove these too."
fi
echo "To rebuild from scratch later: ./setup-all.ps1 (or run 00 through 10 in order directly)."
