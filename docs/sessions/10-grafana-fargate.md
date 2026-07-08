# Session 10 — Grafana on Fargate

## Goal

Add the third ECS service: self-hosted Grafana, provisioned as code, reading metrics from
CloudWatch, reachable through the ALB.

## Prerequisites

- Session 08 done (ECS cluster/ALB/ECR live). Session 09 is a *soft* dependency, not hard: basic
  ECS/ALB CloudWatch metrics (CPUUtilization, RequestCount, TargetResponseTime,
  HTTPCode_Target_5XX_Count) are emitted by AWS by default regardless of Container Insights, so
  dashboards built here work without session 09 — the Container-Insights-level panels and the
  ElastiCache panel will just show no data until session 09's resources exist. Safe to build this
  session concurrently with session 09 (e.g. in a separate git worktree) rather than waiting.

## Deliverables

- `infra/docker/grafana.Dockerfile` — base Grafana image + baked-in provisioning:
  `provisioning/datasources/cloudwatch.yml` (CloudWatch datasource, IAM role for read access to
  CloudWatch metrics) and `provisioning/dashboards/*.json` (app-level dashboard: request rate/
  latency/errors if the backend exports custom metrics; infra dashboard: ECS CPU/mem, ALB
  request count/latency/5xx, ElastiCache CPU/connections).
- `infra/aws-cli-scripts/10-grafana-ecs.sh` — ECR repo push, task def (IAM task role with
  `cloudwatch:GetMetricData`/`ListMetrics`/`DescribeAlarms`), ECS service, ALB target group +
  listener rule for `/grafana/*`.
- Basic auth or Grafana's built-in admin login changed from the default (this is reachable on the
  open ALB pre-session-12, so don't leave default credentials).

## Done criteria

- `http://<alb-dns-name>/grafana` loads Grafana, logged in with non-default credentials, showing
  live ECS/ALB/ElastiCache metrics on the provisioned dashboards.
