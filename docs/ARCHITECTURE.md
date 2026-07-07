# Architecture

A ChatGPT-style multi-user web app: Next.js frontend, FastAPI backend, MongoDB Atlas storage,
OpenAI API for chat/vision, file attachments (image/PDF/Word/Excel) viewable and downloadable in
the chat thread, deployed on AWS ECS Fargate behind an ALB, with self-hosted Grafana on CloudWatch
metrics, and CI/CD via GitHub Actions.

See `docs/ROADMAP.md` for how the build is split into sessions, and `docs/sessions/*.md` for
per-session briefs. This document is the durable reference for *what* we're building; it should
stay accurate as sessions land — update it when a session changes a decision made here.

## Repo layout

```
/frontend                    Next.js 14 App Router, TypeScript, Tailwind CSS
/backend                     FastAPI, Python 3.12
/infra
  /aws-cli-scripts           numbered *.sh scripts, one AWS concern each, idempotent
  /docker                    Dockerfiles, docker-compose.yml
/docs
  ARCHITECTURE.md            this file
  ROADMAP.md                 session index/checklist, source of truth for progress
  /sessions/NN-name.md       one brief per session: scope, inputs, deliverables, done-criteria
.github/workflows/           CI/CD (added in session 11)
README.md
.gitignore
.env.example
```

## Backend (FastAPI)

- **Language/runtime**: Python 3.12, FastAPI, Uvicorn (behind Gunicorn in prod).
- **DB driver**: Motor (async MongoDB driver) against MongoDB Atlas.
- **Auth**: email + password. Bcrypt-hashed passwords. JWT access token (short-lived) + refresh
  token (long-lived), both set as httpOnly, secure, SameSite cookies. Refresh tokens are tracked
  in Redis so logout / revocation actually works (a bare JWT can't be invalidated otherwise).
- **Routers**:
  - `auth` — signup, login, refresh, logout.
  - `conversations` — create/list/rename/delete conversation threads, scoped to the
    authenticated user.
  - `messages` — post a user message (text + optional file references), stream back the
    assistant reply.
  - `files` — upload (returns file metadata + extracted-text preview), download (redirect to a
    presigned S3 URL in prod, direct byte stream in local dev).
- **LLM integration**: OpenAI Chat Completions API. Text messages stream via SSE. Image
  attachments are sent as vision inputs directly to a vision-capable model. PDF/Word/Excel
  attachments are text-extracted server-side (pdfplumber, python-docx, openpyxl/pandas) and the
  extracted text (truncated/chunked to fit context) is injected into the prompt alongside the
  user's question. This is a context-stuffing MVP, not RAG — embeddings/vector search over large
  documents is a possible future enhancement, not built in the initial sessions.
- **File storage**: a small storage-abstraction interface (`storage.py`) with two
  implementations — local disk (dev) and S3 (prod, via boto3, presigned URLs for download).
  MongoDB stores only file metadata (filename, storage key, mimetype, size, extracted-text
  preview) linked to the message that carries it — never the raw bytes.
- **Redis (ElastiCache in prod)**: refresh-token/session blacklist for logout, and per-user
  rate limiting on the chat endpoint. Not used as a generic cache.
- **Config/secrets**: `OPENAI_API_KEY`, `MONGODB_URI`, `JWT_SECRET`, `REDIS_URL` — read from
  environment variables locally (`.env`, via `.env.example` as the template) and from AWS
  Secrets Manager in production (injected as ECS task-definition secrets, never baked into the
  image).

## Frontend (Next.js)

- Next.js App Router, TypeScript, Tailwind CSS.
- Auth pages (login/signup) + a protected layout gated by middleware that checks the JWT cookie
  and redirects to login if absent/expired.
- Sidebar with the user's conversation list; main pane is the chat thread.
- Assistant responses stream token-by-token (reading the backend's SSE stream) for the familiar
  ChatGPT typing effect.
- File attach button in the composer. Inline preview in the message bubble: images render as a
  thumbnail (click to enlarge), PDF/Word/Excel render as an icon card with filename + size.
  Every attachment has a download action that hits the backend's `/files/{id}/download` route.
- Markdown + fenced code block rendering for assistant messages.

## AWS topology (sessions 6-10)

- **VPC**: public + private subnets across 2 AZs. NAT Gateway in a public subnet so
  private-subnet tasks (backend, worker-side calls to OpenAI/MongoDB Atlas) have egress without
  being publicly reachable.
- **ALB**: sits in the public subnets. Path-based routing:
  - `/` → frontend ECS service
  - `/api/*` → backend ECS service
  - `/grafana/*` → grafana ECS service
- **ECS**: one Fargate cluster, three services (frontend, backend, grafana), each with its own
  task definition and ECR repository. Fargate = no EC2 instances to manage.
- **ECR**: one repo per service; GitHub Actions builds and pushes images here on merge to `main`.
- **ElastiCache**: Redis, single node to start, in a private subnet, security-group-restricted to
  the backend service only.
- **Secrets Manager**: holds `OPENAI_API_KEY`, `MONGODB_URI`, `JWT_SECRET`; referenced by ARN in
  the backend task definition so secrets never appear in the image, task def JSON in git, or
  GitHub Actions logs.
- **CloudWatch**: one log group per service (`/ecs/<service-name>`), Container Insights enabled
  on the cluster for CPU/memory/network dashboards, a handful of baseline alarms (task count
  drop, high CPU/mem, ALB 5xx rate).
- **Grafana**: self-hosted on Fargate, not Amazon Managed Grafana. Its datasource
  (CloudWatch) and dashboards are provisioned as code (YAML/JSON baked into the Grafana Docker
  image at build time via its provisioning directories) so the service stays stateless — no EFS
  volume, no persistent disk to manage. Redeploying the image redeploys the dashboards.
- **HTTPS/domain**: intentionally deferred (session 12). Until then everything is served over
  HTTP on the ALB's own `*.elb.amazonaws.com` DNS name — acceptable for early iteration, not
  for real user traffic with credentials, so treat pre-session-12 deployments as staging-only.

## CI/CD (session 11)

- GitHub Actions, triggered on push/merge to `main`.
- Jobs: lint + test (both frontend and backend) → build Docker images → push to ECR → update ECS
  task definitions (new image tag) → `aws ecs update-service --force-new-deployment`.
- AWS auth via GitHub's OIDC provider assuming a scoped IAM role — no long-lived AWS access keys
  stored as GitHub secrets.

## Local development

- `docker-compose.yml` (added session 5) runs frontend + backend + Redis locally. MongoDB is
  Atlas directly (a cloud cluster) even in dev, using a dev-tier connection string, rather than a
  local Mongo container — keeps dev/prod data access code identical.
- File storage uses the local-disk driver in dev so S3 isn't required to develop the app.
