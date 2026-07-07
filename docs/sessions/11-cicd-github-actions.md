# Session 11 — CI/CD via GitHub Actions

## Goal

Automate what sessions 07-10 did by hand: push to `main` → lint/test → build → push to ECR →
redeploy ECS services.

## Prerequisites

- Session 08 done at minimum (ECS services + task defs exist to update); session 10 if Grafana
  should also redeploy automatically.
- Session 06's GitHub OIDC role exists.
- A GitHub repository for this project (create it, or the user provides one, before this session
  — session 00 deliberately did not push to GitHub yet).

## Deliverables

- `.github/workflows/ci.yml` — on PR: lint + test both frontend and backend.
- `.github/workflows/deploy.yml` — on push to `main`: build both Docker images, push to ECR
  (tagged with the commit SHA), render new task-definition revisions with the new image tag,
  `aws ecs update-service --force-new-deployment`, wait for service stability.
- OIDC auth (`aws-actions/configure-aws-credentials` with `role-to-assume`, no static keys).
- Document the rollback procedure (redeploy the previous task-definition revision) in the root
  `README.md`.

## Done criteria

- A commit to `main` results in the new code being live on the ALB DNS name within the workflow's
  run, with no manual AWS CLI steps.
- A deliberately broken commit fails the lint/test job and never reaches ECS.
