# Session 10 — Grafana on Fargate

## Goal

Add the third ECS service: self-hosted Grafana, provisioned as code, reading metrics from
CloudWatch, reachable through the ALB.

## Prerequisites

- Session 09 done (Container Insights + alarms exist, so there's something worth graphing).

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
