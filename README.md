# chatapp — a production ChatGPT-style app

A multi-user, ChatGPT-like web application: chat with an LLM, attach images and documents, and get
streamed responses — built and deployed end to end on AWS with full CI/CD and observability.

**Live:** http://chatapp-alb-811403579.us-east-1.elb.amazonaws.com &nbsp;·&nbsp; **Status:** deployed
and running (HTTP only — HTTPS/custom domain is the one deferred item, see `docs/ROADMAP.md`).

```
Next.js + TypeScript + Tailwind   ──▶   FastAPI + Python 3.12   ──▶   MongoDB Atlas
   (ECS Fargate, private subnet)          (ECS Fargate, private)         + S3 (files)
                        │                          │                     + ElastiCache Redis
                        └──────── ALB ─────────────┘                     + LLM gateway
                     (one DNS name, path-routed)
        Observability: CloudWatch logs + metrics · Grafana · 7 alarms → SNS
        CI/CD: GitHub Actions → OIDC → ECR → ECS (no stored AWS keys)
```

## Features

- **Streaming chat** — assistant responses stream token-by-token over Server-Sent Events.
- **Multi-user auth** — email/password, bcrypt hashing, JWT access + refresh tokens in httpOnly
  cookies, real server-side logout revocation (not just cookie-clearing).
- **File attachments** — images go to the LLM as vision input; PDF/Word/Excel are text-extracted
  server-side and folded into the prompt. All attachments are previewable inline and downloadable.
- **Per-user isolation** — every conversation and file is scoped to its owner.
- **Production hardening** — DB indexes + race-safe signup, IP-based rate limiting on auth
  endpoints, bounded uploads, global exception handling, ECS deployment circuit breaker, exact
  dependency pins (see the production-readiness audit in `docs/ROADMAP.md`).
- **Full observability** — structured JSON logs and custom application metrics in CloudWatch,
  server metrics via Container Insights, all visualized in a self-hosted Grafana dashboard.

## Tech stack

| Area | Choice |
|---|---|
| Frontend | Next.js (App Router), TypeScript, Tailwind CSS |
| Backend | FastAPI, Python 3.12, Uvicorn/Gunicorn |
| Database | MongoDB Atlas (Motor async driver) |
| Cache / sessions | Redis — ElastiCache in prod, `fakeredis` fallback locally |
| LLM | OpenAI SDK against an OpenAI-compatible gateway (streaming + vision) |
| File storage | S3 in prod, local disk in dev (one storage abstraction) |
| Compute | AWS ECS Fargate (backend, frontend, Grafana) |
| Networking | Application Load Balancer, path-based routing, VPC with private subnets |
| Secrets | AWS Secrets Manager (injected into containers at start, never in images) |
| Observability | CloudWatch (logs, EMF metrics, alarms) + self-hosted Grafana |
| CI/CD | GitHub Actions with OIDC auth to AWS (no long-lived keys) |

## Documentation

| File | What it's for |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Lean operational reference — commands, conventions, guardrails. |
| [`docs/PLAYBOOK.md`](docs/PLAYBOOK.md) | **Portable build guide** — how it all fits together and why, the session-by-session recipe, and the hard-won gotchas. Lift into a new repo to build something similar. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Full, current system design — the source of truth for specifics. |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Session checklist, dependency graph, post-roadmap follow-ups. |
| [`docs/sessions/`](docs/sessions/) | One self-contained brief per build session. |
| [`infra/aws-cli-scripts/README.md`](infra/aws-cli-scripts/README.md) | AWS CLI gotchas for the dev machine — read before any AWS command. |

## Project structure

```
/frontend   Next.js App Router (route gate is src/proxy.ts, not middleware.ts)
/backend    FastAPI — app/{core,models,routers,services}, tests/, scripts/
/infra      aws-cli-scripts/ (numbered *.sh + setup-all.ps1 + 99-cleanup.sh), docker/
/docs       PLAYBOOK, ARCHITECTURE, ROADMAP, sessions/
.github/workflows  ci.yml (PR), deploy.yml (push → main)
```

## API surface

All behind the ALB; the backend has no `/api` prefix.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/auth/signup` · `/auth/login` | Create account · sign in (rate-limited by IP) |
| `POST` | `/auth/refresh` · `/auth/logout` | Rotate access token · revoke refresh token |
| `GET` | `/auth/me` | Current authenticated user |
| `GET`/`POST` | `/conversations` | List / create conversations |
| `PATCH`/`DELETE` | `/conversations/{id}` | Rename / delete a conversation |
| `GET`/`POST` | `/conversations/{id}/messages` | List messages / post a message (SSE stream) |
| `POST` | `/conversations/{id}/files` | Upload an attachment |
| `GET` | `/conversations/{id}/files/{file_id}/download` | Download an attachment |
| `GET` | `/health` | Liveness check (used by the ALB) |
| `GET` | `/docs` · `/openapi.json` | Interactive API docs |

## Local development

The full stack (frontend + backend + Redis) runs via Docker Compose. **MongoDB is not
containerized** — both Docker and non-Docker runs talk to the real MongoDB Atlas cluster, so dev
and prod exercise identical data-access code.

```bash
cp .env.example .env    # fill in MONGODB_URI, MONGODB_DB_NAME, JWT_SECRET, OPENAI_API_KEY, OPENAI_BASE_URL
docker compose -f infra/docker/docker-compose.yml up --build
```

- **Frontend:** http://localhost:3000 &nbsp;·&nbsp; **Backend:** http://localhost:8000/health
- Redis is internal-only (no host port). `REDIS_URL` and `NEXT_PUBLIC_API_URL` are set by Compose,
  not sourced from `.env` — see the comments in `docker-compose.yml`/`frontend.Dockerfile` for why
  (`NEXT_PUBLIC_*` is a build-time value inlined into the client bundle, not a runtime one).
- Uploaded files persist in the `chatapp_backend_uploads` named volume across restarts. Tear down
  with `docker compose -f infra/docker/docker-compose.yml down` (add `-v` to also wipe the volume —
  safe locally; Atlas is the real source of truth either way).

Full writeup incl. the build-time-vs-runtime gotcha: `docs/sessions/05-dockerization-local-e2e.md`.

**Without Docker:** run frontend and backend directly; each needs its own env file (`backend/.env`,
`frontend/.env.local`), separate from the root `.env` Compose uses. See sessions 01–04's briefs.

## Testing

```bash
cd backend && ./.venv/Scripts/python -m pytest -q     # 52 tests, no real infra needed
cd frontend && npm run lint && npm run build
```

The backend suite runs entirely against `mongomock-motor` + `fakeredis` — no MongoDB, Redis, AWS, or
LLM credentials required, so it runs standalone in CI. This is exactly what `ci.yml` and
`deploy.yml`'s test gate run.

## Deployment

Push to `main` triggers `deploy.yml`, which **gates on tests passing first** (`backend-tests`,
`frontend-checks`), then builds and pushes all three Docker images to ECR (tagged with the commit
SHA), registers a new ECS task-definition revision per service, force-deploys, waits for stability,
and smoke-tests `/health`, `/login`, `/grafana/api/health` on the live ALB.

AWS auth is via GitHub's OIDC provider assuming the `chatapp-github-deploy` role — **no long-lived
AWS keys are stored in GitHub.** A short-lived STS credential is minted per run, scoped by IAM trust
policy to this repo's `main` branch only.

### Rollback

Every deploy registers a new task-def revision; old revisions are never deleted, so rollback is just
pointing a service at a previous one (no rebuild). Run from a machine with the `default` AWS profile
— and **first** `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` (see
`infra/aws-cli-scripts/README.md` for why):

```bash
# 1. Find a revision (swap chatapp-backend for -frontend / -grafana as needed)
aws ecs list-task-definitions --family-prefix chatapp-backend --sort DESC --profile default --region us-east-1

# 2. Point the service at it and redeploy
aws ecs update-service --cluster chatapp-cluster --service chatapp-backend \
  --task-definition chatapp-backend:<rev> --force-new-deployment --profile default --region us-east-1

# 3. Wait, then confirm health (/health, /login, /grafana/api/health on the ALB)
aws ecs wait services-stable --cluster chatapp-cluster --services chatapp-backend --profile default --region us-east-1
```

Rollback is a temporary mitigation — the next push to `main` redeploys the latest commit.

## Infrastructure & cleanup

AWS is provisioned by numbered, idempotent scripts in `infra/aws-cli-scripts/` (one concern each),
runnable individually or via the `setup-all.ps1` orchestrator. To tear everything down and stop all
billing:

```bash
infra/aws-cli-scripts/99-cleanup.sh --dry-run   # preview what would be deleted
infra/aws-cli-scripts/99-cleanup.sh             # requires typing the project name to confirm
```

## Secrets

Copy `.env.example` to `.env` (repo root, for Docker Compose) and fill in real values. **Never
commit `.env`.** In production, all secrets live only in AWS Secrets Manager and are injected into
containers at start via the ECS execution role — they never appear in an image, in git, or in CI
logs.
