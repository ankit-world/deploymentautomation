#!/usr/bin/env bash
# Session 08 — S3 bucket for file attachment storage (replaces local disk in prod — see
# docs/sessions/08-aws-compute-alb.md correction #2 for why this is necessary, not optional).
#
# Private bucket: all public access blocked. Downloads go through S3Storage.download_url()'s
# presigned URLs (backend/app/services/storage.py), which work fine against a fully private
# bucket since they're signed with the task role's credentials, not a public bucket policy.
#
# Idempotent: head-bucket before create.
#
# Requires: `default` AWS CLI profile.

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

if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
  echo "AWS_ACCOUNT_ID not found in $ENV_FILE — run 00-account-bootstrap.sh first." >&2
  exit 1
fi

BUCKET_NAME="${PROJECT_NAME}-uploads-${AWS_ACCOUNT_ID}-${AWS_REGION}"

echo "== S3 bucket: $BUCKET_NAME =="
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Bucket already exists."
else
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" >/dev/null
  echo "Created bucket."
fi

aws s3api put-public-access-block --bucket "$BUCKET_NAME" --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "Public access blocked."

aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
echo "Default SSE-S3 encryption enabled."

{
  grep -v -E "^S3_BUCKET=" "$ENV_FILE" 2>/dev/null || true
  echo "S3_BUCKET=$BUCKET_NAME"
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. =="
