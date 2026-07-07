# Session 07 — AWS Networking + ECR

**Status**: done (2026-07-08), run interactively with the user (cost confirmation needed before
creating the NAT Gateway — see below).

**What was built**, all via idempotent scripts in `infra/aws-cli-scripts/`:
- `01-vpc.sh` — VPC `vpc-0a512042a5a142333` (10.0.0.0/16), 2 public + 2 private subnets across
  `us-east-1a`/`us-east-1b`, IGW, a single NAT Gateway (shared by both private subnets — cheaper
  than one per AZ), public/private route tables.
- `02-security-groups.sh` — `chatapp-alb-sg` (80/443 from internet), `chatapp-ecs-sg` (3000/8000
  from the ALB SG only), `chatapp-cache-sg` (6379 from the ECS SG only). No SG allows direct
  internet access to ECS tasks or ElastiCache.
- `03-ecr.sh` — three repos: `chatapp-frontend`, `chatapp-backend`, `chatapp-grafana`, image
  scanning on push enabled.
- All resource IDs written to `infra/aws-cli-scripts/.env.aws` (gitignored) for session 08+ to
  source directly instead of re-querying the API.

**Cost confirmation**: flagged to the user before creating the NAT Gateway that it costs ~$32/mo
just existing, exceeding the $20/mo budget alarm from session 06. User has $100 in AWS free-tier
credits and chose to proceed as-is (budget alarm will likely fire on billed-before-credits cost;
that's expected, not a problem).

**Bug found and fixed during verification**: `02-security-groups.sh`'s idempotency check used a
nested JMESPath query (`IpPermissions[?FromPort==...].IpRanges[?CidrIp==...]`) to detect
already-existing ingress rules before creating them — this doesn't work reliably against
`describe-security-groups`' nested projection shape, so re-running the script hit
`InvalidPermission.Duplicate` errors. Fixed by switching to an attempt-then-tolerate pattern:
call `authorize-security-group-ingress` directly and treat the specific
`InvalidPermission.Duplicate` error as success rather than pre-checking. Re-ran the script twice
after the fix to confirm real idempotency (not just "ran once successfully").

**Verified (done criteria)**:
- `aws ec2 describe-vpcs`/`describe-subnets` confirmed the exact topology: 1 VPC, 4 subnets (2
  public with the correct CIDRs/AZs, 2 private), matching the brief.
- `docker push` of a test image (`hello-world`) succeeded to all three ECR repos (confirmed via
  `aws ecr describe-images`), then the test tag was deleted from each repo and the local Docker
  images removed — repos are empty again, ready for session 08's real images.

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
