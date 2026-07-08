# Session 08 — AWS Compute + ALB

**Status**: done (2026-07-08), run interactively with the user. **The app is live**:
`http://chatapp-alb-811403579.us-east-1.elb.amazonaws.com`.

**What was built**, all via idempotent scripts in `infra/aws-cli-scripts/`:
- `04-secrets.sh` — 4 secrets in Secrets Manager (`chatapp/mongodb-uri`, `chatapp/jwt-secret`,
  `chatapp/openai-api-key`, `chatapp/openai-base-url`), values read from `backend/.env` at
  runtime (never hardcoded in the script).
- `04b-s3-bucket.sh` — private bucket `chatapp-uploads-788070448326-us-east-1`, all public access
  blocked, default SSE-S3 encryption.
- `05-ecs-cluster.sh` — Fargate cluster `chatapp-cluster` (Container Insights deliberately off,
  that's session 09).
- `06-alb.sh` — ALB `chatapp-alb` in the public subnets, two target groups (frontend :3000
  health-check `/login`, backend :8000 health-check `/health`), one listener on :80 with a
  priority-10 path-pattern rule (`/auth*`, `/conversations*`, `/health`, `/docs`, `/openapi.json`
  → backend) and a default action → frontend.
- `07-task-defs.sh` — execution role `chatapp-ecs-execution-role` (ECR pull, CloudWatch logs,
  `secretsmanager:GetSecretValue` scoped to the 4 secret ARNs) and task role
  `chatapp-ecs-task-role` (backend only: S3 get/put/delete scoped to the bucket ARN); log groups
  `/ecs/chatapp-backend` and `/ecs/chatapp-frontend`; both task definitions (256 CPU/512MB each —
  Fargate's smallest valid size, deliberate cost control). Backend's container `command` is
  overridden to `gunicorn -k uvicorn.workers.UvicornWorker -w 2` per the Dockerfile's own
  deferred-to-session-08 comment.
- Manual build+push of both images tagged `manual-1` — backend first (no ALB dependency), then
  frontend with `--build-arg NEXT_PUBLIC_API_URL=http://chatapp-alb-811403579.us-east-1.elb.amazonaws.com`.
  Confirmed the URL was actually inlined into the built bundle (`docker cp` + `grep` the static
  chunks) before pushing, same check session 05 used.
- `08-ecs-services.sh` — both ECS services, desired count 1, placed in the *private* subnets
  (`chatapp-ecs-sg`), `assignPublicIp: DISABLED` — only the ALB is internet-facing.

**Two real bugs hit and fixed during this session:**
1. **MSYS2/Git-Bash path mangling.** `aws elbv2 create-target-group --health-check-path /login`
   got silently rewritten to a Windows path (`C:/Program Files/Git/login`) by Git Bash before the
   AWS CLI ever saw it, causing `ValidationError`s on target-group and listener-rule creation
   (the ALB itself was already created and unaffected, being resource-id-based). Fixed with
   `export MSYS_NO_PATHCONV=1` at the top of every script with a leading-`/` argument — see
   `06-alb.sh`'s and `08-ecs-services.sh`'s header comments. Worth remembering for any future
   script with S3 keys, URL paths, or similar leading-slash values on Windows.
2. **Not a bug, but a verification trap**: the live download smoke-test initially looked broken
   (downloaded file hashed to the empty-file SHA256) — actually just `curl` missing `-L`. The
   backend correctly returns a `307` to a presigned S3 URL
   (`S3Storage.download_url`); `curl -L` follows it and the bytes matched the original exactly.
   Recorded here because it looked alarming enough to be worth a note for whoever debugs this
   flow next.

**Live verification performed**, against the real public ALB URL (not a tunnel/localhost):
- `aws elbv2 describe-target-health` — both target groups `healthy`.
- `GET /health` → `{"status":"ok"}`; `GET /login` → `200`; `GET /` (no cookie) → `307` to
  `/login` (route gate works in prod too); `GET /docs` → `200` (path-pattern rule correctly
  routes backend paths through the same ALB hostname the frontend uses).
- Full signup → `GET /auth/me` → create conversation → post a message and captured the real SSE
  stream: token-by-token `"The"` `" capital"` `" of"` `" France"` `" is"` `" Paris"` `"."` then
  `event: done` — a genuine live LLM call from the Fargate backend, through the NAT Gateway, to
  the Euri/Euron gateway (proves outbound internet egress works end-to-end, not just to Atlas).
- File upload → confirmed present in the real S3 bucket via `aws s3 ls` → download (following the
  redirect) → sha256 identical to the original upload.
- Cleanup: deleted the test object from S3, deleted the test user/conversation/messages/file-
  metadata from Atlas (1 user, 1 conversation, 2 messages, 1 file doc).

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
