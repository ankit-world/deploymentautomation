# Session 08 — AWS Compute + ALB

## Goal

Get the frontend and backend actually running in production on ECS Fargate behind the ALB, using
the VPC/ECR from session 07. This is the milestone where the app first becomes reachable on the
public internet.

## Prerequisites

- Session 07 done (VPC + ECR exist).
- Session 05 done (Dockerfiles exist and build successfully).
- Secrets (`OPENAI_API_KEY`, `MONGODB_URI`, `JWT_SECRET`) ready to hand to Secrets Manager.

## Deliverables

- `infra/aws-cli-scripts/04-secrets.sh` — create the three secrets in Secrets Manager.
- `infra/aws-cli-scripts/05-ecs-cluster.sh` — Fargate cluster.
- `infra/aws-cli-scripts/06-task-defs.sh` — task definitions for frontend + backend, secrets
  injected by ARN, log configuration pointing at CloudWatch (log groups created here too).
- `infra/aws-cli-scripts/07-alb.sh` — ALB, target groups (frontend, backend), listener with
  path-based rules (`/api/*` → backend, default → frontend).
- `infra/aws-cli-scripts/08-ecs-services.sh` — ECS services tying task defs to the ALB target
  groups, desired count 1 each to start.
- Manual `docker build` + `docker push` + service update to prove the first deploy.

## Done criteria

- Visiting `http://<alb-dns-name>` loads the frontend; login/chat/file flows work against the
  live backend, Atlas, and OpenAI.
