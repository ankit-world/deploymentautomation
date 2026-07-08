#!/usr/bin/env bash
# Session 10 — Grafana on Fargate: build+push the image, a dedicated CloudWatch-read-only IAM
# task role, task definition, ECS service, and ALB target group + listener rule for /grafana*.
#
# Mirrors the session 08 scripts' conventions (idempotent describe-before-create, .env.aws as the
# source/sink of resource IDs, `default` AWS CLI profile, us-east-1) but folds build+push, IAM,
# task def, target group/listener rule, and service into one script (session 08 split these across
# 06/07/08 because two services shared setup; a single new service doesn't need that split).
#
# IMPORTANT — subpath serving: the ALB forwards the full original path (no rewriting), so a
# request to http://<alb-dns>/grafana/login arrives at the Grafana container as-is, with the
# /grafana prefix still in the path. Grafana must be told to serve from that subpath
# (GF_SERVER_ROOT_URL + GF_SERVER_SERVE_FROM_SUB_PATH=true, set as task-def environment below) or
# its internal routing/static-asset links won't match incoming request paths. Verified locally
# (docker run with the same two env vars) before writing this script: /grafana/login and
# /grafana/api/health both return 200 with correctly `/grafana/`-relative asset links; the
# target-group health-check path below is set to /grafana/api/health to match real routed traffic
# exactly, not the unprefixed /api/health (which happens to also work in 11.3.0, but matching real
# traffic is the more robust choice).
#
# Admin credentials: default admin/admin must not be reachable on the open ALB (session 10 brief).
# This script generates a random password with `openssl rand`, stores it in Secrets Manager
# (mirrors 04-secrets.sh's create-or-update pattern), and injects it into the task definition as a
# `secrets` entry (GF_SECURITY_ADMIN_PASSWORD) — never written to this script, .env.aws, or any
# other file. Retrieve it with:
#   aws secretsmanager get-secret-value --secret-id chatapp/grafana-admin-password \
#     --profile default --region us-east-1 --query SecretString --output text
#
# Requires: 03-ecr.sh, 05-ecs-cluster.sh, 06-alb.sh, 07-task-defs.sh (for EXEC_ROLE_ARN) already
# run. `default` AWS CLI profile. Docker running locally (this script builds the image).

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export MSYS_NO_PATHCONV=1

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
IMAGE_TAG="manual-1"
GRAFANA_PORT=3000

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in AWS_ACCOUNT_ID VPC_ID PRIVATE_SUBNET_A_ID PRIVATE_SUBNET_B_ID ECS_SG_ID \
         CLUSTER_NAME ALB_ARN ALB_DNS_NAME LISTENER_ARN EXEC_ROLE_ARN ECR_GRAFANA_URI; do
  if [ -z "${!v:-}" ]; then
    echo "$v not found in $ENV_FILE — run earlier scripts first (03-ecr, 05-ecs-cluster, 06-alb, 07-task-defs)." >&2
    exit 1
  fi
done

# --- Build + push image ------------------------------------------------------------------------

echo "== Build + push Grafana image =="
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
# `docker build` is a native Windows binary (Docker Desktop), not an MSYS tool — it can't resolve
# a POSIX-style "/c/..." path, but MSYS_NO_PATHCONV=1 (needed above for the AWS CLI's leading-/
# arguments) stops Git Bash from auto-converting one for us. Work around it the same way as the
# leading-/ AWS CLI args: avoid a leading-/ argument entirely by cd-ing into the repo root and
# passing "." as the context, with a relative -f path.
( cd "$REPO_ROOT" \
  && docker build -f infra/docker/grafana.Dockerfile -t "${ECR_GRAFANA_URI}:${IMAGE_TAG}" . )
docker push "${ECR_GRAFANA_URI}:${IMAGE_TAG}"
echo "Pushed ${ECR_GRAFANA_URI}:${IMAGE_TAG}"

# --- Secrets Manager: admin password -------------------------------------------------------------

echo
echo "== Admin password =="
GRAFANA_ADMIN_SECRET_NAME="${PROJECT_NAME}/grafana-admin-password"
GRAFANA_ADMIN_PASSWORD_ARN="$(aws secretsmanager describe-secret --secret-id "$GRAFANA_ADMIN_SECRET_NAME" \
  --query "ARN" --output text 2>/dev/null || true)"
if [ -z "${GRAFANA_ADMIN_PASSWORD_ARN:-}" ] || [ "$GRAFANA_ADMIN_PASSWORD_ARN" = "None" ]; then
  # 32 random chars, alnum-only (no shell-hostile symbols) — generated fresh, never echoed, never
  # written to this script or any file. Only ever lives in Secrets Manager after this point.
  NEW_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
  GRAFANA_ADMIN_PASSWORD_ARN="$(aws secretsmanager create-secret --name "$GRAFANA_ADMIN_SECRET_NAME" \
    --secret-string "$NEW_PASSWORD" --query "ARN" --output text)"
  unset NEW_PASSWORD
  echo "Created secret $GRAFANA_ADMIN_SECRET_NAME (value generated, not printed)."
else
  echo "Secret $GRAFANA_ADMIN_SECRET_NAME already exists — reusing existing password."
fi
echo "Retrieve the password with:"
echo "  aws secretsmanager get-secret-value --secret-id $GRAFANA_ADMIN_SECRET_NAME --profile $AWS_PROFILE --region $AWS_REGION --query SecretString --output text"

# --- IAM: task role (Grafana-only, read-only CloudWatch) ------------------------------------------

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole"}
  ]
}'

TASK_ROLE_NAME="${PROJECT_NAME}-grafana-task-role"
echo
echo "== Task role (grafana): $TASK_ROLE_NAME =="
if aws iam get-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1; then
  echo "Role already exists."
else
  aws iam create-role --role-name "$TASK_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" \
    --description "Grafana ECS task role: read-only CloudWatch metrics access, nothing else." >/dev/null
  echo "Created role."
fi

CLOUDWATCH_READ_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics",
        "cloudwatch:DescribeAlarms"
      ],
      "Resource": "*"
    }
  ]
}'
aws iam put-role-policy --role-name "$TASK_ROLE_NAME" \
  --policy-name "${PROJECT_NAME}-cloudwatch-read" --policy-document "$CLOUDWATCH_READ_POLICY"
GRAFANA_TASK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${TASK_ROLE_NAME}"
echo "Task role ready: $GRAFANA_TASK_ROLE_ARN"

echo
echo "Waiting 10s for IAM propagation..."
sleep 10

# --- CloudWatch log group -------------------------------------------------------------------------

echo
echo "== Log group =="
GRAFANA_LOG_GROUP="/ecs/${PROJECT_NAME}-grafana"
if aws logs describe-log-groups --log-group-name-prefix "$GRAFANA_LOG_GROUP" \
    --query "logGroups[?logGroupName=='$GRAFANA_LOG_GROUP']" --output text | grep -q "$GRAFANA_LOG_GROUP"; then
  echo "Log group $GRAFANA_LOG_GROUP already exists."
else
  aws logs create-log-group --log-group-name "$GRAFANA_LOG_GROUP"
  echo "Created log group $GRAFANA_LOG_GROUP."
fi

# --- Task definition ---------------------------------------------------------------------------
#
# Execution role is the SHARED chatapp-ecs-execution-role (07-task-defs.sh) — it's not scoped to
# anything backend-specific (ECR pull + CloudWatch logs + the 4 backend secrets), and this task's
# only additional secret (GRAFANA_ADMIN_PASSWORD_ARN) needs to be readable by it too, so it's
# granted read access to that secret below, same pattern as the backend's 4 secrets.

echo
echo "== Grant execution role read access to the Grafana admin-password secret =="
EXEC_ROLE_NAME="${PROJECT_NAME}-ecs-execution-role"
GRAFANA_SECRET_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "$GRAFANA_ADMIN_PASSWORD_ARN"
    }
  ]
}
JSON
)"
aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-name "${PROJECT_NAME}-read-grafana-secret" --policy-document "$GRAFANA_SECRET_POLICY"
echo "Granted."

echo
echo "== Grafana task definition =="
GRAFANA_ROOT_URL="http://${ALB_DNS_NAME}/grafana/"
GRAFANA_CONTAINER_DEFS="$(cat <<JSON
[
  {
    "name": "grafana",
    "image": "${ECR_GRAFANA_URI}:${IMAGE_TAG}",
    "portMappings": [{"containerPort": ${GRAFANA_PORT}, "protocol": "tcp"}],
    "environment": [
      {"name": "GF_SECURITY_ADMIN_USER", "value": "admin"},
      {"name": "GF_SERVER_ROOT_URL", "value": "${GRAFANA_ROOT_URL}"},
      {"name": "GF_SERVER_SERVE_FROM_SUB_PATH", "value": "true"}
    ],
    "secrets": [
      {"name": "GF_SECURITY_ADMIN_PASSWORD", "valueFrom": "${GRAFANA_ADMIN_PASSWORD_ARN}"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${GRAFANA_LOG_GROUP}",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
JSON
)"

GRAFANA_TASK_DEF_ARN="$(aws ecs register-task-definition \
  --family "${PROJECT_NAME}-grafana" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 --memory 512 \
  --execution-role-arn "$EXEC_ROLE_ARN" \
  --task-role-arn "$GRAFANA_TASK_ROLE_ARN" \
  --container-definitions "$GRAFANA_CONTAINER_DEFS" \
  --query "taskDefinition.taskDefinitionArn" --output text)"
echo "Registered: $GRAFANA_TASK_DEF_ARN"

# --- ALB: target group + listener rule ----------------------------------------------------------
#
# Purely additive: new target group, new listener rule. Does not touch the existing default action
# (-> frontend) or the priority-10 backend rule (06-alb.sh). Priority 20 (backend uses 10) — lower
# number is evaluated first, no collision as long as it's a distinct, unused priority.

echo
echo "== Target group =="
GRAFANA_TG_ARN="$(aws elbv2 describe-target-groups --names "${PROJECT_NAME}-grafana-tg" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)"
if [ -z "${GRAFANA_TG_ARN:-}" ] || [ "$GRAFANA_TG_ARN" = "None" ]; then
  GRAFANA_TG_ARN="$(aws elbv2 create-target-group --name "${PROJECT_NAME}-grafana-tg" \
    --protocol HTTP --port "$GRAFANA_PORT" --vpc-id "$VPC_ID" --target-type ip \
    --health-check-path "/grafana/api/health" --health-check-protocol HTTP \
    --matcher "HttpCode=200" \
    --query "TargetGroups[0].TargetGroupArn" --output text)"
  echo "Created target group: $GRAFANA_TG_ARN"
else
  echo "Target group already exists: $GRAFANA_TG_ARN"
fi

echo
echo "== Listener rule (/grafana*, priority 20) =="
EXISTING_RULE="$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?Priority=='20'].RuleArn | [0]" --output text 2>/dev/null || true)"
if [ -z "${EXISTING_RULE:-}" ] || [ "$EXISTING_RULE" = "None" ]; then
  aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 20 \
    --conditions "Field=path-pattern,Values=/grafana*" \
    --actions "Type=forward,TargetGroupArn=$GRAFANA_TG_ARN" >/dev/null
  echo "Created /grafana* path-pattern rule (priority 20)."
else
  echo "Grafana path-pattern rule already exists: $EXISTING_RULE"
fi

# --- ECS service -----------------------------------------------------------------------------
#
# chatapp-ecs-sg already allows port 3000 from the ALB SG (it's the same port the frontend
# service uses — confirmed via `aws ec2 describe-security-groups` before writing this script; SG
# rules match on port for anything attached to the SG, not per-service, so no new rule is needed
# for Grafana reusing port 3000).

NETWORK_CONFIG="{\"awsvpcConfiguration\":{\"subnets\":[\"$PRIVATE_SUBNET_A_ID\",\"$PRIVATE_SUBNET_B_ID\"],\"securityGroups\":[\"$ECS_SG_ID\"],\"assignPublicIp\":\"DISABLED\"}}"

# Production-audit follow-up: circuit breaker + auto-rollback, matching backend/frontend (see
# 08-ecs-services.sh) — was off on all three services before this fix.
DEPLOYMENT_CONFIG='deploymentCircuitBreaker={enable=true,rollback=true}'

echo
echo "== Grafana service =="
STATUS="$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "${PROJECT_NAME}-grafana" \
  --query "services[0].status" --output text 2>/dev/null || true)"
if [ "$STATUS" = "ACTIVE" ]; then
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "${PROJECT_NAME}-grafana" \
    --task-definition "$GRAFANA_TASK_DEF_ARN" --force-new-deployment \
    --deployment-configuration "$DEPLOYMENT_CONFIG" >/dev/null
  echo "Updated existing service to $GRAFANA_TASK_DEF_ARN."
else
  aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "${PROJECT_NAME}-grafana" \
    --task-definition "$GRAFANA_TASK_DEF_ARN" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$NETWORK_CONFIG" \
    --load-balancers "targetGroupArn=$GRAFANA_TG_ARN,containerName=grafana,containerPort=${GRAFANA_PORT}" \
    --health-check-grace-period-seconds 60 \
    --deployment-configuration "$DEPLOYMENT_CONFIG" >/dev/null
  echo "Created service ${PROJECT_NAME}-grafana."
fi

echo
echo "== Waiting for service to reach steady state (can take a few minutes) =="
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "${PROJECT_NAME}-grafana"
echo "Service stable."

{
  grep -v -E "^(GRAFANA_TASK_ROLE_ARN|GRAFANA_ADMIN_PASSWORD_ARN|GRAFANA_TASK_DEF_ARN|GRAFANA_TG_ARN|GRAFANA_LOG_GROUP)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
GRAFANA_TASK_ROLE_ARN=$GRAFANA_TASK_ROLE_ARN
GRAFANA_ADMIN_PASSWORD_ARN=$GRAFANA_ADMIN_PASSWORD_ARN
GRAFANA_TASK_DEF_ARN=$GRAFANA_TASK_DEF_ARN
GRAFANA_TG_ARN=$GRAFANA_TG_ARN
GRAFANA_LOG_GROUP=$GRAFANA_LOG_GROUP
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. Grafana should be live at http://${ALB_DNS_NAME}/grafana (login: admin / see Secrets Manager) =="
