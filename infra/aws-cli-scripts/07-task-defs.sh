#!/usr/bin/env bash
# Session 08 — IAM roles, CloudWatch log groups, and ECS task definitions for frontend + backend.
#
# Run AFTER 06-alb.sh (docs/sessions/08-aws-compute-alb.md correction #3): FRONTEND_ORIGIN below
# needs the real ALB DNS name.
#
# IAM roles: execution role (pulls images, writes logs, reads the 4 secrets) is shared by both
# containers; task role (S3 access) is backend-only — frontend makes no AWS API calls at runtime.
# Both are named chatapp-* so they stay within the scope of the session-06 GitHub OIDC deploy
# role's PassRole permission (see docs/sessions/06-aws-account-bootstrap.md).
#
# Backend's container command is overridden to Gunicorn+Uvicorn workers here (not in the
# Dockerfile) — see docs/sessions/08-aws-compute-alb.md correction #4.
#
# Idempotency note: `register-task-definition` has no in-place "update" — every call creates a
# new revision under the same family, which is the normal/expected way ECS task defs work (this
# is also exactly what session 11's CI/CD will do on every deploy). Re-running this script is
# safe; it just produces a newer revision.
#
# Requires: 04-secrets.sh, 04b-s3-bucket.sh, 06-alb.sh already run. `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export MSYS_NO_PATHCONV=1

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
IMAGE_TAG="manual-1"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in AWS_ACCOUNT_ID ALB_DNS_NAME S3_BUCKET ECR_BACKEND_URI ECR_FRONTEND_URI \
         MONGODB_URI_ARN JWT_SECRET_ARN OPENAI_API_KEY_ARN OPENAI_BASE_URL_ARN; do
  if [ -z "${!v:-}" ]; then
    echo "$v not found in $ENV_FILE — run earlier scripts first (04-secrets, 04b-s3-bucket, 06-alb)." >&2
    exit 1
  fi
done

FRONTEND_ORIGIN="http://${ALB_DNS_NAME}"

# --- IAM: execution role ---------------------------------------------------------------------

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole"}
  ]
}'

EXEC_ROLE_NAME="${PROJECT_NAME}-ecs-execution-role"
echo "== Execution role: $EXEC_ROLE_NAME =="
if aws iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1; then
  echo "Role already exists."
else
  aws iam create-role --role-name "$EXEC_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" \
    --description "ECS task execution role: pull from ECR, write CloudWatch logs, read Secrets Manager." >/dev/null
  echo "Created role."
fi
aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

SECRETS_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": [
        "$MONGODB_URI_ARN",
        "$JWT_SECRET_ARN",
        "$OPENAI_API_KEY_ARN",
        "$OPENAI_BASE_URL_ARN"
      ]
    }
  ]
}
JSON
)"
aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-name "${PROJECT_NAME}-read-secrets" --policy-document "$SECRETS_POLICY"
EXEC_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EXEC_ROLE_NAME}"
echo "Execution role ready: $EXEC_ROLE_ARN"

# --- IAM: task role (backend only) ------------------------------------------------------------

TASK_ROLE_NAME="${PROJECT_NAME}-ecs-task-role"
echo
echo "== Task role (backend): $TASK_ROLE_NAME =="
if aws iam get-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1; then
  echo "Role already exists."
else
  aws iam create-role --role-name "$TASK_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" \
    --description "Backend ECS task role: S3 access for file attachment storage." >/dev/null
  echo "Created role."
fi

S3_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
    }
  ]
}
JSON
)"
aws iam put-role-policy --role-name "$TASK_ROLE_NAME" \
  --policy-name "${PROJECT_NAME}-s3-access" --policy-document "$S3_POLICY"
TASK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${TASK_ROLE_NAME}"
echo "Task role ready: $TASK_ROLE_ARN"

# IAM roles/policies can take a few seconds to propagate before ECS can use them.
echo
echo "Waiting 10s for IAM propagation..."
sleep 10

# --- CloudWatch log groups ----------------------------------------------------------------------

echo
echo "== Log groups =="
for lg in "/ecs/${PROJECT_NAME}-backend" "/ecs/${PROJECT_NAME}-frontend"; do
  if aws logs describe-log-groups --log-group-name-prefix "$lg" \
      --query "logGroups[?logGroupName=='$lg']" --output text | grep -q "$lg"; then
    echo "Log group $lg already exists."
  else
    aws logs create-log-group --log-group-name "$lg"
    echo "Created log group $lg."
  fi
done

# --- Task definitions --------------------------------------------------------------------------

echo
echo "== Backend task definition =="
BACKEND_CONTAINER_DEFS="$(cat <<JSON
[
  {
    "name": "backend",
    "image": "${ECR_BACKEND_URI}:${IMAGE_TAG}",
    "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
    "command": ["gunicorn", "app.main:app", "-k", "uvicorn.workers.UvicornWorker", "-w", "2", "--bind", "0.0.0.0:8000", "--access-logfile", "-", "--error-logfile", "-"],
    "environment": [
      {"name": "FRONTEND_ORIGIN", "value": "${FRONTEND_ORIGIN}"},
      {"name": "S3_BUCKET", "value": "${S3_BUCKET}"},
      {"name": "AWS_REGION", "value": "${AWS_REGION}"},
      {"name": "MONGODB_DB_NAME", "value": "chatapp"},
      {"name": "AWS_EMF_SERVICE_NAME", "value": "chatapp-backend"}
    ],
    "secrets": [
      {"name": "MONGODB_URI", "valueFrom": "${MONGODB_URI_ARN}"},
      {"name": "JWT_SECRET", "valueFrom": "${JWT_SECRET_ARN}"},
      {"name": "OPENAI_API_KEY", "valueFrom": "${OPENAI_API_KEY_ARN}"},
      {"name": "OPENAI_BASE_URL", "valueFrom": "${OPENAI_BASE_URL_ARN}"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT_NAME}-backend",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
JSON
)"

BACKEND_TASK_DEF_ARN="$(aws ecs register-task-definition \
  --family "${PROJECT_NAME}-backend" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 --memory 512 \
  --execution-role-arn "$EXEC_ROLE_ARN" \
  --task-role-arn "$TASK_ROLE_ARN" \
  --container-definitions "$BACKEND_CONTAINER_DEFS" \
  --query "taskDefinition.taskDefinitionArn" --output text)"
echo "Registered: $BACKEND_TASK_DEF_ARN"

echo
echo "== Frontend task definition =="
FRONTEND_CONTAINER_DEFS="$(cat <<JSON
[
  {
    "name": "frontend",
    "image": "${ECR_FRONTEND_URI}:${IMAGE_TAG}",
    "portMappings": [{"containerPort": 3000, "protocol": "tcp"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT_NAME}-frontend",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
JSON
)"

FRONTEND_TASK_DEF_ARN="$(aws ecs register-task-definition \
  --family "${PROJECT_NAME}-frontend" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 --memory 512 \
  --execution-role-arn "$EXEC_ROLE_ARN" \
  --container-definitions "$FRONTEND_CONTAINER_DEFS" \
  --query "taskDefinition.taskDefinitionArn" --output text)"
echo "Registered: $FRONTEND_TASK_DEF_ARN"

{
  grep -v -E "^(EXEC_ROLE_ARN|TASK_ROLE_ARN|IMAGE_TAG|BACKEND_TASK_DEF_ARN|FRONTEND_TASK_DEF_ARN)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
EXEC_ROLE_ARN=$EXEC_ROLE_ARN
TASK_ROLE_ARN=$TASK_ROLE_ARN
IMAGE_TAG=$IMAGE_TAG
BACKEND_TASK_DEF_ARN=$BACKEND_TASK_DEF_ARN
FRONTEND_TASK_DEF_ARN=$FRONTEND_TASK_DEF_ARN
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. Images for tag '$IMAGE_TAG' must be pushed to ECR before starting services (08-ecs-services.sh). =="
