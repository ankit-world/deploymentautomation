#!/usr/bin/env bash
# Session 08 — Application Load Balancer: public subnets, two target groups (frontend/backend),
# one listener on :80 with a path-based rule routing the backend's real route prefixes to the
# backend target group (see docs/sessions/08-aws-compute-alb.md correction #1 — there's no
# /api/* prefix, the backend's actual routes are /auth/*, /conversations/*, /health, /docs,
# /openapi.json), default action forwarding everything else to the frontend target group.
#
# Deliberately created BEFORE task defs (correction #3): both NEXT_PUBLIC_API_URL (frontend
# build-arg) and FRONTEND_ORIGIN (backend CORS env var) need this ALB's DNS name, which only
# exists after this script runs.
#
# Idempotent: describe-* by Name before create.
#
# Requires: 01-vpc.sh and 02-security-groups.sh already run. `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# Git-Bash-on-Windows (MSYS2) auto-converts any argument that looks like a Unix absolute path
# ("/login", "/health", "/auth*", ...) into a Windows path before the AWS CLI ever sees it —
# e.g. "/login" silently becomes "C:/Program Files/Git/login". This breaks every health-check
# path and path-pattern condition below unless path conversion is disabled for this script.
export MSYS_NO_PATHCONV=1

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in VPC_ID PUBLIC_SUBNET_A_ID PUBLIC_SUBNET_B_ID ALB_SG_ID; do
  if [ -z "${!v:-}" ]; then
    echo "$v not found in $ENV_FILE — run 01-vpc.sh / 02-security-groups.sh first." >&2
    exit 1
  fi
done

# --- ALB -----------------------------------------------------------------------------------

echo "== ALB =="
ALB_ARN="$(aws elbv2 describe-load-balancers --names "${PROJECT_NAME}-alb" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)"
if [ -z "${ALB_ARN:-}" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --name "${PROJECT_NAME}-alb" \
    --subnets "$PUBLIC_SUBNET_A_ID" "$PUBLIC_SUBNET_B_ID" \
    --security-groups "$ALB_SG_ID" --scheme internet-facing --type application \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)"
  echo "Created ALB $ALB_ARN, waiting for it to become active..."
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
else
  echo "ALB already exists: $ALB_ARN"
fi
ALB_DNS_NAME="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text)"
echo "ALB DNS: $ALB_DNS_NAME"

# --- Target groups ---------------------------------------------------------------------------

create_tg() {
  local name="$1" port="$2" health_path="$3"
  local arn
  arn="$(aws elbv2 describe-target-groups --names "$name" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)"
  if [ -z "${arn:-}" ] || [ "$arn" = "None" ]; then
    arn="$(aws elbv2 create-target-group --name "$name" --protocol HTTP --port "$port" \
      --vpc-id "$VPC_ID" --target-type ip \
      --health-check-path "$health_path" --health-check-protocol HTTP \
      --matcher "HttpCode=200" \
      --query "TargetGroups[0].TargetGroupArn" --output text)"
    echo "Created target group $name: $arn" >&2
  else
    echo "Target group $name already exists: $arn" >&2
  fi
  echo "$arn"
}

echo
echo "== Target groups =="
FRONTEND_TG_ARN="$(create_tg "${PROJECT_NAME}-frontend-tg" 3000 "/login")"
BACKEND_TG_ARN="$(create_tg "${PROJECT_NAME}-backend-tg" 8000 "/health")"

# --- Listener + rules --------------------------------------------------------------------------

echo
echo "== Listener =="
LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`80\`].ListenerArn | [0]" --output text 2>/dev/null || true)"
if [ -z "${LISTENER_ARN:-}" ] || [ "$LISTENER_ARN" = "None" ]; then
  LISTENER_ARN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP \
    --port 80 --default-actions "Type=forward,TargetGroupArn=$FRONTEND_TG_ARN" \
    --query "Listeners[0].ListenerArn" --output text)"
  echo "Created listener (default -> frontend): $LISTENER_ARN"
else
  echo "Listener already exists: $LISTENER_ARN"
fi

# Backend path-pattern rule. Priority 10 (arbitrary, just needs to be lower than any future rule
# so it's evaluated before a catch-all). Re-running: check for an existing rule with the same
# priority before creating a duplicate.
EXISTING_RULE="$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?Priority=='10'].RuleArn | [0]" --output text 2>/dev/null || true)"
if [ -z "${EXISTING_RULE:-}" ] || [ "$EXISTING_RULE" = "None" ]; then
  aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 10 \
    --conditions "Field=path-pattern,Values=/auth*,/conversations*,/health,/docs,/openapi.json" \
    --actions "Type=forward,TargetGroupArn=$BACKEND_TG_ARN" >/dev/null
  echo "Created backend path-pattern rule (priority 10)."
else
  echo "Backend path-pattern rule already exists: $EXISTING_RULE"
fi

{
  grep -v -E "^(ALB_ARN|ALB_DNS_NAME|FRONTEND_TG_ARN|BACKEND_TG_ARN|LISTENER_ARN)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
ALB_ARN=$ALB_ARN
ALB_DNS_NAME=$ALB_DNS_NAME
FRONTEND_TG_ARN=$FRONTEND_TG_ARN
BACKEND_TG_ARN=$BACKEND_TG_ARN
LISTENER_ARN=$LISTENER_ARN
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. App will be reachable at http://$ALB_DNS_NAME once services are running (session 08 later steps). =="
