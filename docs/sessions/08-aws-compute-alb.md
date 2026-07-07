# Session 08 — AWS Compute + ALB

## Goal

Get the frontend and backend actually running in production on ECS Fargate behind the ALB, using
the VPC/ECR from session 07. This is the milestone where the app first becomes reachable on the
public internet.

## Corrections to this brief, found while planning execution

1. **No `/api/*` prefix exists.** The backend's real routes are `/auth/*`, `/conversations/*`
   (covers nested `/conversations/{id}/messages` and `/conversations/{id}/files`), `/health`,
   `/docs`, `/openapi.json` — confirmed directly in `backend/app/routers/*.py`. The ALB's
   path-based rule must match on those literal prefixes, not `/api/*` (which nothing serves).
   `frontend/src/lib/api.ts` already calls `${NEXT_PUBLIC_API_URL}/auth/...` etc. directly (no
   `/api` prefix on the frontend side either), so `NEXT_PUBLIC_API_URL` should just be the ALB's
   own DNS name with no path suffix — one ALB, one hostname, path-routed.
2. **File storage needs real S3, not local disk.** Fargate containers have no persistent disk
   across restarts/redeploys, and with more than one task the disk isn't even shared between
   tasks — `LocalDiskStorage` would silently lose uploaded files or serve 404s depending on which
   task handles which request. `backend/app/services/storage.py` already has an `S3Storage`
   class ready (built in session 02 specifically for this session to wire up) — added an
   `infra/aws-cli-scripts/04b-s3-bucket.sh` step and `S3_BUCKET`/`AWS_REGION` env vars + task-role
   S3 permissions to actually use it. Without this, the brief's own done criteria ("file...flows
   work") can't reliably pass.
3. **Execution order changed: ALB before task definitions**, not after. `NEXT_PUBLIC_API_URL`
   (frontend build-arg) and `FRONTEND_ORIGIN` (backend CORS) both need the ALB's DNS name, which
   only exists once the ALB is created — so task defs (which set `FRONTEND_ORIGIN`) and the image
   builds (which bake in `NEXT_PUBLIC_API_URL`) both have to happen *after* the ALB, not before.
   Script numbering below reflects the real dependency order.
4. **Backend switches to Gunicorn+Uvicorn workers in prod**, per the explicit deferral already
   written in `infra/docker/backend.Dockerfile`'s comment ("Gunicorn fronts Uvicorn in prod...
   deferred to session 08"). Implemented as a task-definition `command` override (not a Dockerfile
   change, so session 05's plain-uvicorn local docker-compose setup is untouched) — `gunicorn`
   added to `backend/requirements.txt`.
5. **ALB health checks need paths that return a plain 200**, not `/` for the frontend — visiting
   `/` unauthenticated returns a 307 redirect to `/login` (`frontend/src/proxy.ts`), which ALB's
   default 200-only matcher would treat as unhealthy. Frontend target group health-checks
   `/login` instead (a genuinely public route that always renders 200). Backend uses `/health` as
   originally planned.
6. **A GitHub Actions deploy role already exists from session 06** (`chatapp-github-deploy`),
   scoped to `iam:PassRole` only on `chatapp-*`-named roles passed to `ecs-tasks.amazonaws.com` —
   this session's new IAM roles must be named with the `chatapp-` prefix to stay inside that
   scope for session 11's CI/CD later.

## Prerequisites

- Session 07 done (VPC + ECR exist).
- Session 05 done (Dockerfiles exist and build successfully).
- Secrets ready in `backend/.env`: `MONGODB_URI`, `JWT_SECRET`, `OPENAI_API_KEY`,
  `OPENAI_BASE_URL` (four, not three — `OPENAI_BASE_URL` is required too since this project uses
  a non-OpenAI gateway, see `docs/ARCHITECTURE.md`'s LLM integration section).

## Deliverables (execution order)

- `infra/aws-cli-scripts/04-secrets.sh` — create the four secrets in Secrets Manager, reading
  real values from `backend/.env` (never pasted into scripts/docs).
- `infra/aws-cli-scripts/04b-s3-bucket.sh` — private S3 bucket for file uploads (block all public
  access; access is via presigned URLs generated server-side, per `S3Storage.download_url`).
- `infra/aws-cli-scripts/05-ecs-cluster.sh` — Fargate cluster (Container Insights is session 09's
  job, not this one — leave it off here).
- `infra/aws-cli-scripts/06-alb.sh` — ALB in the public subnets (`chatapp-alb-sg`), two target
  groups (frontend: ip/3000/health-check `/login`; backend: ip/8000/health-check `/health`),
  listener on :80 with a path-pattern rule matching the backend's real route prefixes (see
  correction #1) forwarding to the backend TG, default action forwarding to the frontend TG.
- `infra/aws-cli-scripts/07-task-defs.sh` — execution role (`chatapp-ecs-execution-role`:
  `AmazonECSTaskExecutionRolePolicy` + inline `secretsmanager:GetSecretValue` scoped to the four
  secret ARNs) and task role (`chatapp-ecs-task-role`, backend only: S3 read/write/delete scoped
  to the bucket ARN), CloudWatch log groups (`/ecs/chatapp-backend`, `/ecs/chatapp-frontend`),
  and the two task definitions — backend's `command` overridden to Gunicorn+Uvicorn workers,
  `FRONTEND_ORIGIN`/`S3_BUCKET`/`AWS_REGION` as plain environment entries, the four secrets
  injected by ARN. Run *after* `06-alb.sh` so `FRONTEND_ORIGIN` can be the real ALB DNS name.
- Manual `docker build --build-arg NEXT_PUBLIC_API_URL=http://<alb-dns-name> ...` + `docker push`
  for both images (backend has no such build-time dependency, build it first) — the first real
  deploy, done manually here; session 11 automates this via GitHub Actions.
- `infra/aws-cli-scripts/08-ecs-services.sh` — ECS services tying the task defs to the ALB target
  groups, placed in the *private* subnets (egress via session 07's NAT Gateway, not directly
  internet-reachable) with `chatapp-ecs-sg`, desired count 1 each to start.

## Done criteria

- Visiting `http://<alb-dns-name>` loads the frontend; login/chat/file flows work against the
  live backend, Atlas, and OpenAI — verified by actually driving it (e.g. headless Chromium),
  same standard prior sessions used, not just curling `/health`.
