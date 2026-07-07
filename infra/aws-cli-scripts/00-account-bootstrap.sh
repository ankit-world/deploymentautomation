#!/usr/bin/env bash
# Session 06 — AWS account bootstrap.
#
# Idempotent: safe to re-run. Creates/verifies:
#   1. A monthly budget alarm (email alert, no SNS topic needed).
#   2. An IAM OIDC identity provider trusting token.actions.githubusercontent.com.
#   3. An IAM role GitHub Actions can assume (trust policy scoped to this exact repo, main
#      branch only) with a policy scoped to ECR push + ECS deploy — not full admin.
#
# Writes resulting resource identifiers to .env.aws (gitignored) so later numbered scripts
# (session 07+) can source it instead of re-querying the AWS API.
#
# Requires: AWS CLI configured under the `default` profile (an admin IAM user, `ankitexp`,
# created directly by the project owner — see docs/sessions/06-aws-account-bootstrap.md for why
# this deviates from the original "scoped local-CLI user" plan). There is no dedicated named
# profile for this project anymore — `default` IS `ankitexp`/788070448326 (the old unrelated
# `github`/other-account profile and the separate `chatapp` profile were both removed from
# ~/.aws/credentials and ~/.aws/config directly by the project owner). openssl must be on PATH
# (used to fetch GitHub's current OIDC TLS thumbprint rather than hardcoding one, which goes
# stale).

set -euo pipefail

# This machine has AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY set as environment variables from an
# unrelated, unidentified source (not User/Machine Windows env vars, not in the usual shell
# profile files — see docs/sessions/06-aws-account-bootstrap.md for the investigation). Env-var
# credentials take precedence over --profile/AWS_PROFILE in the AWS CLI's credential chain no
# matter what, so they MUST be unset here or every command in this script silently targets the
# wrong AWS account. This is now the ONLY thing standing between a plain `aws` command and the
# wrong account, since `default` itself is correctly `ankitexp` — there's no longer a
# wrong-by-default *profile* to accidentally pick, just these env vars silently winning over the
# correct default. Confirmed still present and still resolving to the old `github` account as of
# the region-fix follow-up (see docs/sessions/06-aws-account-bootstrap.md).
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
GITHUB_REPO="ankit-world/deploymentautomation"
BUDGET_LIMIT_USD="20"
BUDGET_NOTIFY_EMAIL="ankitmarwaha7@gmail.com"
DEPLOY_ROLE_NAME="${PROJECT_NAME}-github-deploy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"

export AWS_PROFILE AWS_REGION

echo "== Resolving account id =="
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Account: $ACCOUNT_ID"

# --- 1. Budget alarm --------------------------------------------------------------------------

echo
echo "== Budget alarm ($BUDGET_LIMIT_USD USD/month) =="
if aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$PROJECT_NAME-monthly" >/dev/null 2>&1; then
  echo "Budget '$PROJECT_NAME-monthly' already exists, skipping create."
else
  aws budgets create-budget \
    --account-id "$ACCOUNT_ID" \
    --budget "{
      \"BudgetName\": \"$PROJECT_NAME-monthly\",
      \"BudgetLimit\": {\"Amount\": \"$BUDGET_LIMIT_USD\", \"Unit\": \"USD\"},
      \"TimeUnit\": \"MONTHLY\",
      \"BudgetType\": \"COST\"
    }" \
    --notifications-with-subscribers "[
      {
        \"Notification\": {
          \"NotificationType\": \"ACTUAL\",
          \"ComparisonOperator\": \"GREATER_THAN\",
          \"Threshold\": 80,
          \"ThresholdType\": \"PERCENTAGE\"
        },
        \"Subscribers\": [{\"SubscriptionType\": \"EMAIL\", \"Address\": \"$BUDGET_NOTIFY_EMAIL\"}]
      },
      {
        \"Notification\": {
          \"NotificationType\": \"FORECASTED\",
          \"ComparisonOperator\": \"GREATER_THAN\",
          \"Threshold\": 100,
          \"ThresholdType\": \"PERCENTAGE\"
        },
        \"Subscribers\": [{\"SubscriptionType\": \"EMAIL\", \"Address\": \"$BUDGET_NOTIFY_EMAIL\"}]
      }
    ]"
  echo "Created budget '$PROJECT_NAME-monthly'."
fi

# --- 2. GitHub OIDC identity provider ---------------------------------------------------------

echo
echo "== GitHub OIDC identity provider =="
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "OIDC provider already exists: $OIDC_PROVIDER_ARN"
else
  THUMBPRINT="$(echo | openssl s_client -servername token.actions.githubusercontent.com \
      -connect token.actions.githubusercontent.com:443 -showcerts 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout \
    | sed 's/.*Fingerprint=//; s/://g' | tr 'A-Z' 'a-z')"
  echo "Computed live thumbprint: $THUMBPRINT"

  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "$THUMBPRINT" >/dev/null
  echo "Created OIDC provider: $OIDC_PROVIDER_ARN"
fi

# --- 3. Deploy role GitHub Actions assumes ----------------------------------------------------

echo
echo "== Deploy role: $DEPLOY_ROLE_NAME =="

TRUST_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Federated": "$OIDC_PROVIDER_ARN"},
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
        "StringLike": {"token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:ref:refs/heads/main"}
      }
    }
  ]
}
JSON
)"

if aws iam get-role --role-name "$DEPLOY_ROLE_NAME" >/dev/null 2>&1; then
  echo "Role already exists, updating trust policy to current values."
  aws iam update-assume-role-policy --role-name "$DEPLOY_ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  aws iam create-role \
    --role-name "$DEPLOY_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Assumed by GitHub Actions (main branch only) in $GITHUB_REPO to push to ECR and deploy to ECS." >/dev/null
  echo "Created role $DEPLOY_ROLE_NAME."
fi

DEPLOY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DEPLOY_ROLE_NAME}"

# Scoped permissions: ECR push + ECS deploy, not admin. iam:PassRole is restricted to roles this
# project's task definitions will use (session 08) and further constrained to only being passed
# to the ecs-tasks service, so this role can't be used to pass an unrelated privileged role.
DEPLOY_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${PROJECT_NAME}-*"
    },
    {
      "Sid": "EcsDeploy",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassEcsTaskRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT_NAME}-*",
      "Condition": {
        "StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}
      }
    }
  ]
}
JSON
)"

aws iam put-role-policy \
  --role-name "$DEPLOY_ROLE_NAME" \
  --policy-name "${PROJECT_NAME}-deploy-scope" \
  --policy-document "$DEPLOY_POLICY"
echo "Attached/updated inline policy '${PROJECT_NAME}-deploy-scope' on $DEPLOY_ROLE_NAME."

# --- Write .env.aws ----------------------------------------------------------------------------

cat > "$ENV_FILE" <<EOF
# Generated by 00-account-bootstrap.sh — gitignored, sourced by later numbered scripts.
PROJECT_NAME=$PROJECT_NAME
AWS_PROFILE=$AWS_PROFILE
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$ACCOUNT_ID
GITHUB_REPO=$GITHUB_REPO
OIDC_PROVIDER_ARN=$OIDC_PROVIDER_ARN
GITHUB_DEPLOY_ROLE_ARN=$DEPLOY_ROLE_ARN
EOF
echo
echo "Wrote $ENV_FILE"
echo
echo "== Done. Remaining manual step: enable MFA on the AWS root account via the console. =="
