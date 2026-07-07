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
- **LLM integration**: OpenAI Chat Completions API via the official `openai` Python SDK, but
  `OPENAI_BASE_URL` actually points at a third-party OpenAI-*compatible* gateway (Euri/Euron,
  `https://api.euron.one/api/v1/euri`), not `api.openai.com` — set via `base_url=` on the SDK
  client. Verified in session 02 (see `app/services/llm.py`'s module docstring and
  `docs/sessions/02-backend-llm-files.md` for the live-test evidence):
  - The gateway is a multi-provider router: `GET /models` lists real-looking OpenAI, Anthropic,
    Google, Meta, and Groq model ids all proxied through this one endpoint. Never assume a
    specific model name exists without checking that list first. `gpt-4o-mini` is used as the
    default (`settings.openai_model`) — present, non-premium (cheap), and vision-capable.
  - `stream=True` behaves exactly like real OpenAI: standard `ChatCompletionChunk` objects,
    `chunk.choices[0].delta.content` per token. No divergence found — text messages stream via
    SSE, token-by-token, all the way through to the frontend.
  - Vision works: `image_url` content parts with a base64 data URI are accepted by `gpt-4o-mini`
    and produce accurate answers about image content. `settings.vision_supported` (default
    `True`) gates this path; if a future model swap turns out not to support vision, flip it and
    image attachments degrade to an inline text note instead of an API error (implemented and
    unit tested even though not currently needed).
  - PDF/Word/Excel attachments are text-extracted server-side (pdfplumber, python-docx,
    openpyxl) and the extracted text (truncated to `settings.extracted_text_max_chars`, default
    20k) is injected into the prompt alongside the user's question. This is a context-stuffing
    MVP, not RAG — embeddings/vector search over large documents is a possible future
    enhancement, not built in the initial sessions.
  - The chat endpoint (`POST /conversations/{id}/messages`) responds `text/event-stream` with a
    small custom SSE protocol: `event: user_message` (fired immediately so the client has the
    persisted user message's id before tokens arrive), repeated `event: token` deltas, an
    `event: error` if the LLM call fails, and a final `event: done` with the persisted assistant
    message. HTTP status is 200 (not 201) since the response is a stream, not a single created
    resource.
- **File storage**: a small storage-abstraction interface (`storage.py`) with two
  implementations — local disk (dev) and S3 (prod, via boto3, presigned URLs for download).
  MongoDB stores only file metadata (filename, storage key, mimetype, size, extracted-text
  preview) linked to the message that carries it — never the raw bytes.
- **Redis (ElastiCache in prod)**: refresh-token/session blacklist for logout, and per-user
  rate limiting on the chat endpoint (session 02, fixed-window INCR/EXPIRE counter). Not used as
  a generic cache. This dev machine has no local Redis server, so when `REDIS_URL` is unset the
  app automatically falls back to `fakeredis`'s async client (`app/core/redis_client.py`), which
  implements the same `redis.asyncio` interface in-memory — the rate-limit code itself is
  provider-agnostic and needs no changes once real Redis/ElastiCache exists (session 09).
- **Config/secrets**: `OPENAI_API_KEY`, `MONGODB_URI`, `JWT_SECRET`, `REDIS_URL` — read from
  environment variables locally (`.env`, via `.env.example` as the template) and from AWS
  Secrets Manager in production (injected as ECS task-definition secrets, never baked into the
  image).

## Frontend (Next.js)

- Next.js App Router, TypeScript, Tailwind CSS. Scaffolded (session 03) via `create-next-app`,
  which installed **Next.js 16**. Next 16 renamed the `middleware.ts` file convention to
  `proxy.ts` (function `proxy` instead of `middleware`) — the route gate lives at
  `frontend/src/proxy.ts`. If you're used to `middleware.ts` from training data or older docs,
  see `frontend/AGENTS.md` (auto-generated by the scaffolder) and the comment at the top of
  `proxy.ts` before assuming the old convention still applies.
- Auth pages (login/signup) posting directly to the backend's cookie-based auth endpoints with
  `credentials: 'include'` — no client-side token storage, the browser handles the httpOnly
  cookies.
- **Route gate is two-layer**, decided in session 03 after working through what's actually
  feasible with httpOnly cookies:
  1. `frontend/src/proxy.ts` runs server-side and checks for the mere *presence* of the
     `access_token` cookie (httpOnly blocks client-side JS from reading cookies, not server-side
     code — proxy sees the raw `Cookie` header same as any backend). It does **not** validate the
     JWT's signature or expiry: doing so would require duplicating `JWT_SECRET` into frontend
     code (an unwanted trust-boundary leak) or a network call to the backend on every navigation.
     Missing cookie -> redirect to `/login`. Present cookie on `/login`/`/signup` -> redirect to
     `/`.
  2. `AuthContext` (`frontend/src/contexts/AuthContext.tsx`) is the authoritative check: it calls
     `GET /auth/me` on mount and treats any 401 (even after an attempted `POST /auth/refresh`) as
     unauthenticated, redirecting client-side. This catches the case proxy's presence check can't
     — a cookie that's present but expired/invalid.

  This mirrors the "optimistic check in middleware/proxy + authoritative check via a real data
  call" pattern Next.js's own authentication guide recommends for stateless sessions.
- Sidebar with the user's conversation list; main pane is the chat thread.
- **Local dev note**: the backend (`:8000`) and frontend (`:3000`) cookies interoperate without
  extra config because browser cookie-domain matching ignores port — a cookie set by
  `http://localhost:8000` (host `localhost`, no explicit `Domain` attribute) is sent on requests
  to `http://localhost:3000` too, since both share the host `localhost`. This is also why
  `proxy.ts` (running as part of the Next.js server on `:3000`) can see cookies the backend set.
  This assumption should keep holding in AWS too, since the ALB routes `/` and `/api/*` on the
  *same* DNS name (see "AWS topology" below) — revisit if that ever changes.
- Session 03 (`docs/sessions/03-frontend-core.md`) shipped the chat pane buffering the whole SSE
  reply and rendering it only on `event: done` — no token-by-token typing effect yet. That's
  session 04's job, along with the items below:
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
