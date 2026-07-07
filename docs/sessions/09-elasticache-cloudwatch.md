# Session 09 — ElastiCache + CloudWatch

## Goal

Provision the Redis cluster the backend already expects (session 02 built the rate-limit/session
code against `REDIS_URL`) and round out observability beyond the basic log groups from session 08.

## Prerequisites

- Session 08 done (ECS services + VPC/security groups live).

## Deliverables

- `infra/aws-cli-scripts/09-elasticache.sh` — single-node Redis cluster in the private subnet,
  restricted to the ECS task security group.
- Update the backend task definition/secret with the real `REDIS_URL`, redeploy.
- Enable Container Insights on the ECS cluster.
- CloudWatch alarms: ECS running-task-count < desired, CPU/memory > 80%, ALB 5xx rate above a
  threshold — wired to an SNS topic (email subscription is enough for now).

## Done criteria

- Backend logs show Redis connections succeeding; logout actually invalidates the refresh token
  (proves Redis is wired, not just reachable).
- Alarms visible and in `OK` state in the CloudWatch console.
