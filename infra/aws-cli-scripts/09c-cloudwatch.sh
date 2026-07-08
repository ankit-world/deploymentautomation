#!/usr/bin/env bash
# Session 09 — Container Insights + CloudWatch alarms wired to an SNS topic.
#
# 1. Enables Container Insights on chatapp-cluster (session 08's 05-ecs-cluster.sh deliberately
#    left this off, deferring to this session — see that script's header comment). Needed for the
#    per-service RunningTaskCount/DesiredTaskCount metrics the task-count alarms below use — those
#    aren't published under plain AWS/ECS, only ECS/ContainerInsights.
# 2. SNS topic + email subscription (same email as session 06's budget alarm,
#    docs/sessions/06-aws-account-bootstrap.md) — email subscriptions require a one-time
#    confirmation click this script can't do for you; it prints a reminder at the end.
# 3. Seven alarms, all pointed at that topic:
#    - chatapp-backend-running-tasks / chatapp-frontend-running-tasks: DesiredTaskCount minus
#      RunningTaskCount > 0 (metric math, not a hardcoded "< 1" — stays correct if desired count
#      is ever scaled up from today's 1).
#    - chatapp-backend-cpu-high / chatapp-backend-memory-high / chatapp-frontend-cpu-high /
#      chatapp-frontend-memory-high: AWS/ECS service-level CPUUtilization/MemoryUtilization > 80%
#      (this metric is published regardless of Container Insights, so these 4 don't actually
#      depend on step 1 — kept here anyway since they're the same "service health" concern).
#    - chatapp-alb-5xx-rate-high: HTTPCode_Target_5XX_Count / RequestCount * 100 > 5%, metric math
#      over the whole ALB (both target groups combined; --treat-missing-data notBreaching so a
#      quiet period with zero requests doesn't false-alarm on a divide-by-zero/no-datapoint).
#
# put-metric-alarm is naturally idempotent (upsert by AlarmName); SNS create-topic returns the
# existing ARN if the name already exists. The email subscribe call is guarded by a describe check
# so re-running this script doesn't spam a second confirmation email.
#
# Requires: 05-ecs-cluster.sh, 06-alb.sh, 07-task-defs.sh, 08-ecs-services.sh already run.
# `default` AWS CLI profile.

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export MSYS_NO_PATHCONV=1

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
ALERT_EMAIL="ankitmarwaha7@gmail.com"
SNS_TOPIC_NAME="${PROJECT_NAME}-alerts"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in AWS_ACCOUNT_ID CLUSTER_NAME ALB_ARN BACKEND_TG_ARN FRONTEND_TG_ARN; do
  if [ -z "${!v:-}" ]; then
    echo "$v not found in $ENV_FILE — run earlier scripts first." >&2
    exit 1
  fi
done

# --- 1. Container Insights ------------------------------------------------------------------

echo "== Container Insights on $CLUSTER_NAME =="
CURRENT_SETTING="$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
  --query "clusters[0].settings[?name=='containerInsights'].value | [0]" --output text 2>/dev/null || true)"
if [ "$CURRENT_SETTING" = "enabled" ]; then
  echo "Already enabled."
else
  aws ecs update-cluster-settings --cluster "$CLUSTER_NAME" \
    --settings name=containerInsights,value=enabled >/dev/null
  echo "Enabled."
fi

# --- 2. SNS topic + email subscription --------------------------------------------------------

echo
echo "== SNS topic: $SNS_TOPIC_NAME =="
SNS_TOPIC_ARN="$(aws sns create-topic --name "$SNS_TOPIC_NAME" --query "TopicArn" --output text)"
echo "Topic: $SNS_TOPIC_ARN"

EXISTING_SUB="$(aws sns list-subscriptions-by-topic --topic-arn "$SNS_TOPIC_ARN" \
  --query "Subscriptions[?Endpoint=='$ALERT_EMAIL'] | [0].SubscriptionArn" --output text 2>/dev/null || true)"
if [ -n "$EXISTING_SUB" ] && [ "$EXISTING_SUB" != "None" ]; then
  echo "Email subscription already exists (status: $EXISTING_SUB)."
else
  aws sns subscribe --topic-arn "$SNS_TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null
  echo "Subscription requested for $ALERT_EMAIL — REQUIRES a one-time confirmation click in that"
  echo "inbox before alarm notifications will actually be delivered (same as session 06's budget"
  echo "alarm email; this script cannot click it for you)."
fi

# --- 3. Alarms -----------------------------------------------------------------------------------

ALB_DIM="${ALB_ARN#*loadbalancer/}"
BACKEND_TG_DIM="targetgroup/${BACKEND_TG_ARN#*:targetgroup/}"
FRONTEND_TG_DIM="targetgroup/${FRONTEND_TG_ARN#*:targetgroup/}"

echo
echo "== Running-task-count alarms (desired > running) =="
for svc in backend frontend; do
  SERVICE_NAME="${PROJECT_NAME}-${svc}"
  ALARM_NAME="${PROJECT_NAME}-${svc}-running-tasks"
  METRICS="$(cat <<JSON
[
  {
    "Id": "running",
    "MetricStat": {
      "Metric": {
        "Namespace": "ECS/ContainerInsights",
        "MetricName": "RunningTaskCount",
        "Dimensions": [
          {"Name": "ClusterName", "Value": "${CLUSTER_NAME}"},
          {"Name": "ServiceName", "Value": "${SERVICE_NAME}"}
        ]
      },
      "Period": 60,
      "Stat": "Minimum"
    },
    "ReturnData": false
  },
  {
    "Id": "desired",
    "MetricStat": {
      "Metric": {
        "Namespace": "ECS/ContainerInsights",
        "MetricName": "DesiredTaskCount",
        "Dimensions": [
          {"Name": "ClusterName", "Value": "${CLUSTER_NAME}"},
          {"Name": "ServiceName", "Value": "${SERVICE_NAME}"}
        ]
      },
      "Period": 60,
      "Stat": "Maximum"
    },
    "ReturnData": false
  },
  {
    "Id": "shortfall",
    "Expression": "desired - running",
    "Label": "Desired minus running tasks",
    "ReturnData": true
  }
]
JSON
)"
  aws cloudwatch put-metric-alarm \
    --alarm-name "$ALARM_NAME" \
    --alarm-description "chatapp-${svc}: fewer running tasks than desired (deploy stuck, task crash-looping, etc.)" \
    --metrics "$METRICS" \
    --comparison-operator GreaterThanThreshold \
    --threshold 0 \
    --evaluation-periods 3 \
    --datapoints-to-alarm 3 \
    --treat-missing-data notBreaching \
    --alarm-actions "$SNS_TOPIC_ARN" \
    --ok-actions "$SNS_TOPIC_ARN"
  echo "Alarm ready: $ALARM_NAME"
done

echo
echo "== CPU / memory > 80% alarms =="
for svc in backend frontend; do
  SERVICE_NAME="${PROJECT_NAME}-${svc}"
  for metric in CPUUtilization MemoryUtilization; do
    label="cpu"; [ "$metric" = "MemoryUtilization" ] && label="memory"
    ALARM_NAME="${PROJECT_NAME}-${svc}-${label}-high"
    aws cloudwatch put-metric-alarm \
      --alarm-name "$ALARM_NAME" \
      --alarm-description "chatapp-${svc}: ${metric} above 80% for 10 minutes" \
      --namespace "AWS/ECS" \
      --metric-name "$metric" \
      --dimensions "Name=ClusterName,Value=${CLUSTER_NAME}" "Name=ServiceName,Value=${SERVICE_NAME}" \
      --statistic Average \
      --period 300 \
      --threshold 80 \
      --comparison-operator GreaterThanThreshold \
      --evaluation-periods 2 \
      --datapoints-to-alarm 2 \
      --treat-missing-data notBreaching \
      --alarm-actions "$SNS_TOPIC_ARN" \
      --ok-actions "$SNS_TOPIC_ARN"
    echo "Alarm ready: $ALARM_NAME"
  done
done

echo
echo "== ALB target 5xx rate alarm =="
FIVE_XX_METRICS="$(cat <<JSON
[
  {
    "Id": "err5xx",
    "MetricStat": {
      "Metric": {
        "Namespace": "AWS/ApplicationELB",
        "MetricName": "HTTPCode_Target_5XX_Count",
        "Dimensions": [{"Name": "LoadBalancer", "Value": "${ALB_DIM}"}]
      },
      "Period": 300,
      "Stat": "Sum"
    },
    "ReturnData": false
  },
  {
    "Id": "reqs",
    "MetricStat": {
      "Metric": {
        "Namespace": "AWS/ApplicationELB",
        "MetricName": "RequestCount",
        "Dimensions": [{"Name": "LoadBalancer", "Value": "${ALB_DIM}"}]
      },
      "Period": 300,
      "Stat": "Sum"
    },
    "ReturnData": false
  },
  {
    "Id": "err_rate",
    "Expression": "(err5xx / reqs) * 100",
    "Label": "5xx rate (%)",
    "ReturnData": true
  }
]
JSON
)"
aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT_NAME}-alb-5xx-rate-high" \
  --alarm-description "chatapp ALB: target 5xx rate above 5% over 5 minutes" \
  --metrics "$FIVE_XX_METRICS" \
  --comparison-operator GreaterThanThreshold \
  --threshold 5 \
  --evaluation-periods 1 \
  --datapoints-to-alarm 1 \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --ok-actions "$SNS_TOPIC_ARN"
echo "Alarm ready: ${PROJECT_NAME}-alb-5xx-rate-high"

{
  grep -v -E "^(SNS_TOPIC_ARN|SNS_TOPIC_NAME)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
SNS_TOPIC_ARN=$SNS_TOPIC_ARN
SNS_TOPIC_NAME=$SNS_TOPIC_NAME
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo
echo "== Done. 7 alarms created, wired to $SNS_TOPIC_ARN. =="
echo "== REMINDER: confirm the SNS email subscription in ${ALERT_EMAIL}'s inbox — alarms won't =="
echo "== actually deliver notifications until that one-time click happens.                      =="
