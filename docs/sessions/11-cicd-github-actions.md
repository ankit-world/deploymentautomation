# Session 11 — CI/CD via GitHub Actions

## Goal

Automate what sessions 07-10 did by hand: push to `main` → lint/test → build → push to ECR →
redeploy ECS services.

## Corrections to this brief, found while planning execution

1. **The GitHub repo already exists and has been used since session 00** —
   https://github.com/ankit-world/deploymentautomation, every session so far has committed and
   pushed directly to `main` (no PR-based workflow has been used yet in this project). Ignore the
   brief's old "create it before this session" line.
2. **Three services now exist, not two.** Session 10 added Grafana as a third ECS service
   (`chatapp-grafana`). "Build both Docker images" should be "build all three" — backend,
   frontend, and Grafana all need the same build→push→redeploy treatment.
3. **Session 06's OIDC deploy role (`chatapp-github-deploy`) should already have everything this
   workflow needs** — verify rather than re-provision: ECR push scoped to `chatapp-*` repos, ECS
   `DescribeServices`/`DescribeTaskDefinition`/`RegisterTaskDefinition`/`UpdateService`, and
   `iam:PassRole` scoped to `chatapp-*` roles (covers the execution role and both task roles,
   since they're all named `chatapp-*`). Trust policy only allows assumption from
   `repo:ankit-world/deploymentautomation:ref:refs/heads/main` — this means `deploy.yml` (push to
   `main`) can assume it, but `ci.yml` running on a pull request cannot (different `sub` claim
   shape) — that's fine, `ci.yml` doesn't need AWS credentials at all, only `deploy.yml` does. If
   you find a genuine permission gap once actually running the workflow, extend the existing
   role's inline policy (`infra/aws-cli-scripts/00-account-bootstrap.sh`'s pattern) rather than
   creating a new role.
4. **The first push to `main` that adds `deploy.yml` will immediately trigger a real deployment**
   (GitHub Actions evaluates workflow files present in the very commit being pushed against a
   matching trigger) — this is expected and is in fact the natural way to prove the done criteria,
   not a surprise to guard against. The app is live and has real (if synthetic) verification data
   flowing through it from prior sessions — make sure this first automated deploy actually
   succeeds and leaves all three services healthy, the same standard every manual deploy so far
   has been held to.
5. Don't forget workflow YAML needs `permissions: id-token: write` (plus `contents: read`) for
   `aws-actions/configure-aws-credentials`'s OIDC role assumption to work at all — a common
   omission that fails silently as a permissions error at runtime, not at workflow-syntax time.

## Prerequisites

- Sessions 08, 09, 10 done (all three ECS services + task defs exist to update).
- Session 06's GitHub OIDC role exists (verify its scope per correction #3 above).

## Deliverables

- `.github/workflows/ci.yml` — on PR: lint + test both frontend and backend (reuse
  `backend/tests` via `pytest` and the frontend's `npm run lint`/`npm run build`, same commands
  sessions 01-05 already established locally — see `backend/README.md`, `frontend/README.md`).
- `.github/workflows/deploy.yml` — on push to `main`: build all three Docker images, push to ECR
  (tagged with the commit SHA), render new task-definition revisions with the new image tag for
  each (fetch the current task def via `describe-task-definition`, replace only the image URI,
  `register-task-definition` — same pattern every manual deploy in sessions 08-10 already used),
  `aws ecs update-service --force-new-deployment` for each service, wait for service stability.
- OIDC auth (`aws-actions/configure-aws-credentials` with `role-to-assume: chatapp-github-deploy`,
  no static keys).
- Document the rollback procedure (redeploy the previous task-definition revision) in the root
  `README.md`.

## Done criteria

- A commit to `main` results in the new code being live on the ALB DNS name within the workflow's
  run, with no manual AWS CLI steps — verify this for real, not just that the workflow reports
  success (curl the live ALB, or drive an actual request through it, after the run completes).
- A deliberately broken commit (on a throwaway PR, since this project doesn't otherwise use PRs)
  fails the lint/test job and never reaches ECS.
