#!/usr/bin/env bash
# Session 08 — Secrets Manager: MONGODB_URI, JWT_SECRET, OPENAI_API_KEY, OPENAI_BASE_URL.
#
# Reads real values from backend/.env at runtime (gitignored, never committed) — this script
# file itself contains no secret values, only the mechanism to read and upload them.
#
# Idempotent: creates each secret if missing, otherwise updates its value (put-secret-value) so
# re-running after rotating a key in backend/.env pushes the new value.
#
# Requires: `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
BACKEND_ENV_FILE="$REPO_ROOT/backend/.env"

if [ ! -f "$BACKEND_ENV_FILE" ]; then
  echo "backend/.env not found at $BACKEND_ENV_FILE — cannot read secret values." >&2
  exit 1
fi

read_env_value() {
  # Reads KEY=value from backend/.env, stripping the key and any surrounding whitespace. Does
  # not echo the value to stdout of the calling context beyond what's needed for the AWS CLI call.
  grep -E "^$1=" "$BACKEND_ENV_FILE" | tail -n1 | cut -d'=' -f2-
}

put_secret() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    echo "Value for $name is empty in backend/.env — skipping." >&2
    return
  fi
  local arn
  arn="$(aws secretsmanager describe-secret --secret-id "$name" \
    --query "ARN" --output text 2>/dev/null || true)"
  if [ -z "${arn:-}" ] || [ "$arn" = "None" ]; then
    arn="$(aws secretsmanager create-secret --name "$name" --secret-string "$value" \
      --query "ARN" --output text)"
    echo "Created secret $name" >&2
  else
    aws secretsmanager put-secret-value --secret-id "$name" --secret-string "$value" >/dev/null
    echo "Updated secret $name" >&2
  fi
  echo "$arn"
}

echo "== Secrets Manager =="
MONGODB_URI_ARN="$(put_secret "${PROJECT_NAME}/mongodb-uri" "$(read_env_value MONGODB_URI)")"
JWT_SECRET_ARN="$(put_secret "${PROJECT_NAME}/jwt-secret" "$(read_env_value JWT_SECRET)")"
OPENAI_API_KEY_ARN="$(put_secret "${PROJECT_NAME}/openai-api-key" "$(read_env_value OPENAI_API_KEY)")"
OPENAI_BASE_URL_ARN="$(put_secret "${PROJECT_NAME}/openai-base-url" "$(read_env_value OPENAI_BASE_URL)")"

{
  grep -v -E "^(MONGODB_URI_ARN|JWT_SECRET_ARN|OPENAI_API_KEY_ARN|OPENAI_BASE_URL_ARN)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
MONGODB_URI_ARN=$MONGODB_URI_ARN
JWT_SECRET_ARN=$JWT_SECRET_ARN
OPENAI_API_KEY_ARN=$OPENAI_API_KEY_ARN
OPENAI_BASE_URL_ARN=$OPENAI_BASE_URL_ARN
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote ARNs to $ENV_FILE (secret values themselves are only ever in AWS + backend/.env)."
echo "== Done. =="
