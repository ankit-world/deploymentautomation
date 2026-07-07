# Session 07 — AWS Networking + ECR

## Goal

Provision the VPC (public + private subnets, NAT, security groups) and ECR repositories via
numbered AWS CLI scripts under `infra/aws-cli-scripts/`. First real AWS spend starts here (NAT
Gateway is hourly-billed) — confirm with the user before running scripts that create billable
resources.

## Prerequisites

- Session 06 done (`aws sts get-caller-identity` works under the project profile).

## Deliverables

- `infra/aws-cli-scripts/01-vpc.sh` — VPC, 2 public + 2 private subnets across 2 AZs, internet
  gateway, NAT gateway, route tables.
- `infra/aws-cli-scripts/02-security-groups.sh` — SG for ALB (80/443 from internet), SG for ECS
  tasks (only from ALB SG), SG for ElastiCache (only from ECS task SG).
- `infra/aws-cli-scripts/03-ecr.sh` — repos: `<project>-frontend`, `<project>-backend`,
  `<project>-grafana`.
- Each script writes the resource IDs it creates to `infra/aws-cli-scripts/.env.aws` (gitignored)
  so later scripts can reference them without re-querying the API.
- Scripts are idempotent: check-before-create so re-running doesn't fail or duplicate resources.

## Done criteria

- `aws ec2 describe-vpcs`/`describe-subnets` show the expected topology.
- `docker push` of a test image to each ECR repo succeeds.
