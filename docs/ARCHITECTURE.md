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
- Session 04 (`docs/sessions/04-frontend-chat-experience.md`) upgraded the session-03 chat pane
  from "buffer the whole SSE reply, render on `event: done`" to the full experience, verified live
  against the real backend/Atlas/LLM gateway:
  - **Token-by-token streaming**: `c/[id]/page.tsx` now accumulates `event: token` deltas into a
    transient `streamingMessage` piece of state (rendered as its own `MessageBubble`), replaced by
    the real persisted message once `event: done` arrives. `messages.ts`'s SSE parser itself was
    unchanged — session 03 already built it, session 04 just consumes `onToken`.
  - **File attachments**: `frontend/src/lib/files.ts` — `uploadFile()` (multipart
    `POST /conversations/{id}/files`) uses `XMLHttpRequest`, not `fetch`, specifically for
    `xhr.upload.onprogress` (fetch has no upload-progress event, and a multi-MB PDF/xlsx upload
    needs a real progress bar). The composer supports multiple queued attachments, each
    independently retryable. `downloadFile()`/`fetchFileBlob()` fetch the file as a `Blob` (with
    the same cookie-auth + 401-refresh-retry pattern as `apiFetch`) rather than using a bare
    `<a href>` or `<img src>` pointed at the backend — **judgment call**: the download route sets
    `Content-Disposition: attachment` on every response including images, and that header's effect
    on an `<img>` subresource load vs. a top-level navigation is inconsistent across browsers,
    so blob-fetch-then-object-URL is used uniformly for both inline thumbnails and explicit
    downloads. Verified byte-identical (sha256) round trips for PNG/PDF/DOCX/XLSX through the real
    upload → LLM → download path, including confirming the LLM actually received each file's
    content (asked a question whose answer only exists inside the attached file).
  - **Inline previews**: `frontend/src/components/Attachment.tsx` — images render as an `<img>`
    thumbnail from the blob object URL (click to enlarge via a simple full-screen overlay, no
    lightbox library); PDF/Word/Excel render as an icon card with filename + formatted size.
  - **Markdown**: `react-markdown` + `remark-gfm` + `rehype-highlight` (highlight.js) +
    `@tailwindcss/typography`'s `prose` classes, applied only to assistant messages (user messages
    stay plain `whitespace-pre-wrap` text). Tailwind v4 has no `tailwind.config.js` by default
    (CSS-first config) — the typography plugin is registered via `@plugin "@tailwindcss/
    typography";` directly in `globals.css`, not a config file's `plugins` array.
  - **Loading/error/retry**: chat send failures show an inline error banner with a Retry button
    that resends the same content/fileIds; each upload chip in the composer has its own
    uploading/done/error state with a per-file retry.

## AWS topology (sessions 6-10)

- **Account/CLI setup (session 06)**: account `788070448326`, CLI profile `default` (no separate
  named profile — see `infra/aws-cli-scripts/README.md` for why), IAM user `ankitexp`
  (`AdministratorAccess` — a deliberate deviation from least-privilege, see
  `docs/sessions/06-aws-account-bootstrap.md`), region `us-east-1`. GitHub Actions deploy role:
  `chatapp-github-deploy`, assumable only from `repo:ankit-world/deploymentautomation` on the
  `main` branch via OIDC (no static keys in GitHub secrets). **Before running any AWS CLI command
  for this project**, read `infra/aws-cli-scripts/README.md` — this machine has stray
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars from an unidentified source that silently
  override even `default`, and once caused resources to be created in the wrong AWS account.
- **VPC (session 07, live)**: `vpc-0a512042a5a142333` (10.0.0.0/16) — public + private subnets
  across `us-east-1a`/`us-east-1b`. A single NAT Gateway (not one per AZ — cost tradeoff, ~$32/mo
  alone) in the public subnet so private-subnet tasks (backend, worker-side calls to OpenAI/
  MongoDB Atlas) have egress without being publicly reachable. Security groups: `chatapp-alb-sg`
  (80/443 from internet), `chatapp-ecs-sg` (app ports from the ALB SG only), `chatapp-cache-sg`
  (6379 from the ECS SG only) — nothing but the ALB is reachable from the open internet. All
  resource IDs in `infra/aws-cli-scripts/.env.aws` (gitignored); provisioned by
  `infra/aws-cli-scripts/01-vpc.sh` and `02-security-groups.sh`.
- **ALB (session 08, live)**: `chatapp-alb`, public subnets, DNS name
  `chatapp-alb-811403579.us-east-1.elb.amazonaws.com` — **the app is live at
  `http://` + that hostname**. Path-based routing on the one listener (:80): a priority-10 rule
  matching the backend's *actual* route prefixes (`/auth*`, `/conversations*`, `/health`, `/docs`,
  `/openapi.json` — NOT `/api/*`, which nothing serves; the backend has no `/api` prefix, see
  `docs/sessions/08-aws-compute-alb.md` correction #1) forwards to the backend target group;
  everything else (default action) forwards to the frontend target group. A priority-20 rule
  (session 10, live) matching `path-pattern=/grafana*` forwards to the Grafana target group.
  One ALB hostname, shared by all three services — `NEXT_PUBLIC_API_URL` (frontend build-arg) and `FRONTEND_ORIGIN` (backend
  CORS) are both this same DNS name. Target-group
  health checks: backend `/health`, frontend `/login` (not `/`, which 307-redirects unauthenticated
  requests and would fail ALB's default 200-only matcher), Grafana `/grafana/api/health` (the
  path includes the `/grafana` prefix because Grafana is configured to serve from that subpath —
  see the "Grafana" bullet below — matching how the ALB forwards the request path unmodified).
- **ECS (session 08, live; session 10 added Grafana)**: Fargate cluster `chatapp-cluster`, three
  services (`chatapp-backend`, `chatapp-frontend`, `chatapp-grafana`), desired count 1 each, placed in
  the *private* subnets (`chatapp-ecs-sg`, no public IP — only reachable via the ALB), 256 CPU /
  512MB task size each (Fargate's smallest valid size, deliberate cost control). Execution role
  `chatapp-ecs-execution-role` (ECR pull, CloudWatch logs, reads the 4 backend Secrets Manager
  secrets plus, as of session 10, the Grafana admin-password secret) is shared by all three
  services; task roles are per-service and scoped tightly: `chatapp-ecs-task-role` (backend only,
  S3 access), `chatapp-grafana-task-role` (session 10, Grafana only, read-only CloudWatch —
  `cloudwatch:GetMetricData`/`ListMetrics`/`DescribeAlarms`, nothing else). Backend's container
  command is overridden to `gunicorn -k uvicorn.workers.UvicornWorker -w 2` (not the Dockerfile's
  default plain `uvicorn`, which stays as-is for local/docker-compose use). First deploy of
  frontend/backend was a manual `docker build`/`push`/`create-service` (image tag `manual-1`);
  Grafana's session-10 deploy followed the same manual `manual-1` pattern via
  `infra/aws-cli-scripts/10-grafana-ecs.sh`; session 11 automates all three going forward.
- **ECR (session 07, live)**: `chatapp-frontend`, `chatapp-backend`, `chatapp-grafana`
  (`788070448326.dkr.ecr.us-east-1.amazonaws.com/chatapp-*`, scan-on-push enabled), provisioned by
  `infra/aws-cli-scripts/03-ecr.sh`. All three now hold real `manual-1` images running in
  production (`chatapp-grafana` since session 10).
- **S3 (session 08, live)**: private bucket `chatapp-uploads-788070448326-us-east-1` (all public
  access blocked, default SSE-S3 encryption) replaces local-disk file storage in production —
  Fargate containers have no persistent/shared disk, so this isn't optional (see
  `docs/sessions/08-aws-compute-alb.md` correction #2). `backend/app/services/storage.py`'s
  `S3Storage` (built in session 02 specifically for this) generates presigned URLs for downloads;
  the backend redirects to them (`307`) rather than proxying bytes itself.
- **ElastiCache**: Redis, single node to start, in a private subnet, security-group-restricted to
  the backend service only. Not live yet — session 09.
- **Secrets Manager (session 08, live)**: `chatapp/mongodb-uri`, `chatapp/jwt-secret`,
  `chatapp/openai-api-key`, `chatapp/openai-base-url` — four, not three; `OPENAI_BASE_URL` is
  required too since this project uses a non-OpenAI gateway. Referenced by ARN in the backend
  task definition (`infra/aws-cli-scripts/07-task-defs.sh`) so secrets never appear in the image,
  task def JSON in git, or GitHub Actions logs. `FRONTEND_ORIGIN`/`S3_BUCKET`/`AWS_REGION` are
  plain (non-secret) task-definition environment entries, not Secrets Manager entries. Session 10
  added a fifth secret, `chatapp/grafana-admin-password` — a random string generated by
  `10-grafana-ecs.sh` (`openssl rand`), never written to any file in this repo, injected into the
  Grafana task definition as `GF_SECURITY_ADMIN_PASSWORD`.
- **CloudWatch (partial)**: log groups `/ecs/chatapp-backend`/`/ecs/chatapp-frontend`/
  `/ecs/chatapp-grafana` (the last one added session 10) exist and are receiving real logs.
  Container Insights and alarms are session 09.
- **Grafana (session 10, live)**: self-hosted on Fargate (service `chatapp-grafana`, task family
  `chatapp-grafana`), not Amazon Managed Grafana. Its datasource (CloudWatch, auth via
  `chatapp-grafana-task-role`, no static AWS keys) and dashboards are provisioned as code
  (`infra/docker/grafana/provisioning/`, baked into the Grafana Docker image at build time) so the
  service stays stateless — no EFS volume, no persistent disk to manage. Redeploying the image
  redeploys the dashboards. Reachable at `http://<alb-dns-name>/grafana` via the ALB's
  priority-20 listener rule; Grafana is configured with `GF_SERVER_ROOT_URL`/
  `GF_SERVER_SERVE_FROM_SUB_PATH=true` to serve correctly from that `/grafana` subpath, since the
  ALB forwards the request path unmodified rather than stripping the prefix. Login is `admin` +
  the generated password in `chatapp/grafana-admin-password` (Secrets Manager) — the default
  `admin`/`admin` login is rejected. One provisioned dashboard (`chatapp-infra`) covers ECS
  CPU/memory and ALB request count/latency/5xx (all confirmed showing live data); ElastiCache and
  Container-Insights-level panels are wired up but show "No data" until session 09's resources
  exist (see `docs/sessions/10-grafana-fargate.md`).
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

- `infra/docker/docker-compose.yml` (added session 05) runs frontend + backend + Redis locally.
  MongoDB is Atlas directly (a cloud cluster) even in dev, using a dev-tier connection string,
  rather than a local Mongo container — keeps dev/prod data access code identical.
- File storage uses the local-disk driver in dev so S3 isn't required to develop the app. Under
  Docker, the backend's `UPLOAD_DIR` is overridden to `/data/uploads`, the mount point of a named
  volume (`chatapp_backend_uploads`), so uploaded files survive `docker compose restart`/recreate.
  **Gotcha**: the backend container runs as a non-root user, and a brand-new Docker named volume's
  mount point is owned by `root` unless the image already has that directory pre-created (with the
  right ownership) at build time — `backend.Dockerfile` does this explicitly
  (`mkdir -p /data/uploads && chown -R app:app /data/uploads` before `USER app`); skip it and the
  first upload fails with `PermissionError`.
- **`NEXT_PUBLIC_API_URL` is a browser-side, build-time value, not a runtime one.** The frontend
  calls the backend directly from the browser (see "Frontend (Next.js)" above — no Next.js server
  proxy), and Next.js inlines `NEXT_PUBLIC_*` vars into the client JS bundle during `next build`.
  `infra/docker/frontend.Dockerfile` therefore takes it as a Docker build **ARG** (not a
  `docker-compose.yml` runtime `environment:` entry, which would have no effect on an
  already-built image), set to the **host-published** backend port (`http://localhost:8000`) since
  the browser runs on the host, not inside the Docker network. `REDIS_URL` is the mirror-image
  case: read server-side by the backend container itself, so it correctly uses the
  Docker-internal service name (`redis://redis:6379/0`), set via `docker-compose.yml`'s
  `environment:`. Same reasoning applies to `FRONTEND_ORIGIN` (CORS): must be
  `http://localhost:3000`, the host-published frontend port, matching what the browser actually
  sends as `Origin`.
- `frontend/next.config.ts` has `output: "standalone"` (added session 05) so the Docker runtime
  stage only needs `.next/standalone` + `.next/static` + `public`, not the full `node_modules`
  tree — smaller/faster image. No effect on `next dev`.
- Both Dockerfiles are multi-stage (`infra/docker/backend.Dockerfile`: Python 3.12,
  builder-venv-then-copy; `infra/docker/frontend.Dockerfile`: Node 22, deps-builder-runtime), run
  as non-root users, and never bake secrets into a layer — `docker-compose.yml` injects
  `MONGODB_URI`/`MONGODB_DB_NAME`/`JWT_SECRET`/`OPENAI_API_KEY`/`OPENAI_BASE_URL` via `env_file:`
  from a root `.env` (gitignored) at container runtime, same principle production uses with
  Secrets Manager (session 08).
- Both services' `build.context` in `docker-compose.yml` is the **repo root** (not each app's own
  subdirectory) even though the Dockerfiles live under `infra/docker/` — sidesteps Docker
  Compose's context-relative `dockerfile:` path resolution rule, which gets confusing once the
  Dockerfile's directory, the compose file's directory, and the app's directory are all different.
  A root `.dockerignore` (mirrors `.gitignore`) keeps the build context transfer from churning
  through `node_modules`/`.venv`/`.git`.
