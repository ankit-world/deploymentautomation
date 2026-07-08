#!/usr/bin/env bash
# Session 09 — wire the real ElastiCache endpoint into the backend and redeploy.
#
# Registers a new chatapp-backend task-definition revision (task defs are immutable per revision
# — same idempotency note as 07-task-defs.sh) with REDIS_URL added to the container's plain
# `environment` (not `secrets`/Secrets Manager: an in-VPC ElastiCache endpoint isn't sensitive the
# way a DB connection string with embedded credentials is — same reasoning as FRONTEND_ORIGIN/
# S3_BUCKET already being plain env entries there), otherwise byte-for-byte identical to the
# backend container definition 07-task-defs.sh registered. No code change was needed for the
# backend to pick this up (app/core/redis_client.py already reads REDIS_URL and only falls back
# to fakeredis when it's unset — see docs/ARCHITECTURE.md "Redis").
#
# Then forces a new deployment of chatapp-backend onto that revision and waits for the service to
# stabilize, same pattern 08-ecs-services.sh used. Frontend is untouched.
#
# Correction found while executing this session: `docs/sessions/09-elasticache-cloudwatch.md`
# assumed no backend code change was needed (redis_client.py already reads REDIS_URL). That's true
# for the rate limiter, but `app/routers/auth.py`'s `logout` turned out to be cookie-clear-only —
# no server-side revocation existed at all, contradicting docs/ARCHITECTURE.md's "Redis" section.
# Added a real Redis-backed refresh-token blacklist (app/core/token_blacklist.py) so this
# session's done-criteria ("logout actually invalidates the refresh token") is actually true, not
# just "Redis is reachable". That means the image tagged `manual-1` (session 08) is stale — this
# script
# builds/expects a new image tag (default `session09-1`, override via BACKEND_IMAGE_TAG env var)
# with that fix, NOT the shared `IMAGE_TAG` from earlier scripts (which the frontend still uses
# unchanged).
#
# Requires: 09-elasticache.sh already run (REDIS_URL in .env.aws), 07-task-defs.sh /
# 08-ecs-services.sh already run (backend service exists), and the new backend image already
# built+pushed to ECR under BACKEND_IMAGE_TAG (this script does not build/push images itself).
# `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export MSYS_NO_PATHCONV=1

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
BACKEND_IMAGE_TAG="${BACKEND_IMAGE_TAG:-session09-1}"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in AWS_ACCOUNT_ID ALB_DNS_NAME S3_BUCKET ECR_BACKEND_URI CLUSTER_NAME \
         EXEC_ROLE_ARN TASK_ROLE_ARN REDIS_URL \
         MONGODB_URI_ARN JWT_SECRET_ARN OPENAI_API_KEY_ARN OPENAI_BASE_URL_ARN; do
  if [ -z "${!v:-}" ]; then
    echo "$v not found in $ENV_FILE — run 07-task-defs.sh / 09-elasticache.sh first." >&2
    exit 1
  fi
done

FRONTEND_ORIGIN="http://${ALB_DNS_NAME}"

echo "== Registering new backend task definition revision with REDIS_URL =="
BACKEND_CONTAINER_DEFS="$(cat <<JSON
[
  {
    "name": "backend",
    "image": "${ECR_BACKEND_URI}:${BACKEND_IMAGE_TAG}",
    "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
    "command": ["gunicorn", "app.main:app", "-k", "uvicorn.workers.UvicornWorker", "-w", "2", "--bind", "0.0.0.0:8000", "--access-logfile", "-", "--error-logfile", "-"],
    "environment": [
      {"name": "FRONTEND_ORIGIN", "value": "${FRONTEND_ORIGIN}"},
      {"name": "S3_BUCKET", "value": "${S3_BUCKET}"},
      {"name": "AWS_REGION", "value": "${AWS_REGION}"},
      {"name": "MONGODB_DB_NAME", "value": "chatapp"},
      {"name": "REDIS_URL", "value": "${REDIS_URL}"}
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
echo "== Deploying to chatapp-backend service =="
aws ecs update-service --cluster "$CLUSTER_NAME" --service "${PROJECT_NAME}-backend" \
  --task-definition "$BACKEND_TASK_DEF_ARN" --force-new-deployment >/dev/null
echo "Update requested, waiting for the service to stabilize (this can take a few minutes)..."

aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "${PROJECT_NAME}-backend"
echo "Service stable."

{
  grep -v -E "^(BACKEND_TASK_DEF_ARN|BACKEND_IMAGE_TAG)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
BACKEND_TASK_DEF_ARN=$BACKEND_TASK_DEF_ARN
BACKEND_IMAGE_TAG=$BACKEND_IMAGE_TAG
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. Backend is running on a task definition with REDIS_URL set. =="
