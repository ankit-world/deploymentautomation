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
- **Redis (ElastiCache in prod, live session 09)**: refresh-token blacklist for logout
  (`app/core/token_blacklist.py`, session 09 — keyed by a SHA-256 hash of the token, entry TTL =
  the token's own remaining lifetime), and per-user rate limiting on the chat endpoint (session 02,
  fixed-window INCR/EXPIRE counter). Not used as a generic cache. This dev machine has no local
  Redis server, so when `REDIS_URL` is unset the app automatically falls back to `fakeredis`'s
  async client (`app/core/redis_client.py`), which implements the same `redis.asyncio` interface
  in-memory — both the rate-limit and blacklist code are provider-agnostic and needed no further
  changes once real Redis/ElastiCache existed. **Correction**: until session 09, `POST
  /auth/logout` was actually cookie-clear-only — no server-side revocation existed despite this
  section previously describing it as already working (see
  `docs/sessions/09-elasticache-cloudwatch.md`'s "Correction" section for the full story and live
  proof: replaying a pre-logout refresh token now gets `401` from `POST /auth/refresh`).
- **Config/secrets**: `OPENAI_API_KEY`, `MONGODB_URI`, `JWT_SECRET`, `REDIS_URL` — read from
  environment variables locally (`.env`, via `.env.example` as the template) and from AWS
  Secrets Manager in production (injected as ECS task-definition secrets, never baked into the
  image).
- **Lifespan**: `app/main.py` uses a FastAPI `lifespan` context manager to close the Motor and
  Redis connection pools gracefully on shutdown (`app/core/db.py`'s `close_db()`,
  `app/core/redis_client.py`'s `close_redis()`) — ECS sends SIGTERM on every rolling redeploy
  (automatic since session 11), so this matters in practice, not just in theory. Deliberately no
  matching startup ping: `tests/conftest.py`'s `TestClient(app)` runs the real lifespan on every
  test (function-scoped fixture, 36 tests), and `dependency_overrides` only intercepts
  `Depends()`-injected calls during request handling — a ping inside `lifespan` would bypass the
  test suite's mocked DB and hang against the default `mongodb://localhost:27017` (~30s Motor
  server-selection timeout) once per test.
- **Structured logging (`app/core/logging_config.py`)**: JSON log lines to stdout, shipped to
  CloudWatch via the same `awslogs` pipeline every container already uses — the original request
  asked to "log each and everything... inside CloudWatch," but until this was added the entire
  backend had exactly two `logger.` calls total (an LLM-failure and an extraction-failure
  exception handler); everything else was gunicorn's bare access log with no user identity. Now:
  every request gets a structured "request completed" log (method/route/status/duration_ms,
  plus `user_id` resolved best-effort from the access-token cookie — see
  `app/main.py`'s `observability_middleware`, which emits this alongside the existing metrics
  call), and every user-facing action gets its own event log with context: signup/login/logout
  (`app/routers/auth.py`), conversation create/delete (`conversations.py`), chat message sent and
  LLM-call failure (`messages.py`), file upload/download (`files.py`). Hand-rolled JSON formatter
  rather than a third-party dependency (the format is simple enough not to need one — contrast
  with `app/core/metrics.py`'s EMF choice, where the wire format genuinely is fiddly enough to
  warrant the official library). One real gotcha hit while building this: `filename` is a
  reserved `logging.LogRecord` attribute name — passing it via `extra={"filename": ...}` raises
  `KeyError` at the `logger.info()` call site, not at format time; renamed to `uploaded_filename`
  in `files.py`'s log calls once this surfaced via a real test failure.
  ALB *access* logs (per-request client-IP/latency records) were considered as a companion to
  this but deliberately not built — they land in S3, not CloudWatch (AWS offers no CloudWatch
  Logs destination for that specific feature), which doesn't match the literal "inside CloudWatch"
  ask this section is responding to.
- **Production-readiness audit (2026-07-08)**: a proactive sweep for other missed best practices,
  triggered by the lifespan gap above. Findings and fixes, all live-verified (real tests plus a
  real local run against production Atlas, not just code review):
  - **DB indexes + signup race**: no indexes existed anywhere (`backend/scripts/ensure_indexes.py`
    is a standalone idempotent script, run manually — already applied to production Atlas — not
    called from `lifespan`, since every container replica racing to create indexes on every
    restart is worse than a one-time manual step). `auth.py`'s signup pre-checks `find_one` for a
    duplicate email, which is a fast path, not the actual guarantee; the real guarantee is now the
    unique index plus a caught `DuplicateKeyError` around the insert, closing the TOCTOU race
    between two concurrent signups with the same email.
  - **Auth rate limiting**: `/auth/signup` and `/auth/login` had none — only the post-auth chat
    endpoint did. Can't key by `user_id` pre-auth, so `app/core/rate_limit.py`'s new
    `enforce_auth_rate_limit` keys by client IP, read from `X-Forwarded-For` (the ALB always
    appends the real client IP; `request.client.host` alone would just be the ALB's own address).
  - **Unbounded upload reads**: `files.py` read the full request body into memory *before*
    checking it against `max_upload_size_mb`, so the size limit didn't bound memory use, just
    rejected after the fact. Now reads at most `max_bytes + 1`.
  - **`deploy.yml` had no test gate**: it built and deployed on every push to `main` regardless of
    whether tests passed. Added `backend-tests`/`frontend-checks` jobs (mirroring `ci.yml`) and
    made `deploy` depend on both via `needs:`.
  - **No global exception handler**: an unhandled exception in any route crashed straight through
    to a bare framework error. Tried the obvious `@app.exception_handler(Exception)` first; a real
    test proved it doesn't fire when `BaseHTTPMiddleware`-style middleware is registered (a known
    Starlette/FastAPI interaction gap, confirmed here rather than assumed) — the exception
    propagated past the handler to the test client instead of being converted. Fixed by moving the
    try/except directly into `observability_middleware`'s `call_next()` call instead of a separate
    handler; now logs the full structured traceback and returns a clean `{"detail": "Internal
    server error"}` 500. Confirmed working against a *real*, non-synthetic failure during the live
    smoke test below (a transient local DNS resolution error reaching Atlas), not just the
    purpose-built test.
  - **Unbounded list endpoints**: `GET /conversations` and `GET /conversations/{id}/messages` had
    no cap — an account's data would grow every response forever. Added
    `max_conversations_returned`/`max_messages_returned` (generous defaults, a backstop not a
    UX-facing pagination scheme). The messages endpoint needed care: capping via `.limit()` on an
    ascending sort would keep the *oldest* N messages, not the most recent N, silently freezing a
    long conversation's visible history at its beginning — fixed by sorting descending, limiting,
    then reversing in Python.
  - **Loose dependency pins**: `requirements.txt` used `>=` throughout; rewritten to exact `==`
    pins from real installed versions (`pip freeze`), for reproducible builds.
  - **No LLM request timeout**: `AsyncOpenAI` had no `timeout=`, so a stalled gateway response
    would tie up server resources for the SDK's own default (minutes) instead of failing out to
    the chat endpoint's existing error-handling path. Set to 60s.
  - **No frontend error boundary**: an unhandled render error fell through to Next's bare default
    crash screen. Added `frontend/src/app/error.tsx` (route-segment errors) and
    `global-error.tsx` (root-layout errors, which `error.tsx` structurally can't catch since it
    renders inside the layout it would need to replace).
  - **No ECS deployment circuit breaker**: a bad task definition would keep being redeployed
    indefinitely rather than rolling back automatically. Added
    `deploymentCircuitBreaker={enable=true,rollback=true}` to all three services' deployment
    configuration — applied live via `aws ecs update-service`, not just checked into the
    provisioning scripts, and confirmed via `describe-services` on all three.
  - **Deliberately deferred**: multi-instance redundancy (`desiredCount` > 1 per service) was
    surfaced but left as-is — real ongoing AWS cost (roughly doubling compute spend) for
    resilience this project doesn't need yet at its current traffic/scale, consistent with the
    cost-conscious choices made throughout the AWS sessions.

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
- **ElastiCache (session 09, live)**: single-node Redis cluster `chatapp-redis` (`cache.t3.micro`,
  engine Redis 7.1), private subnets (`chatapp-cache-subnet-group`, spanning both), restricted to
  `chatapp-ecs-sg` via `chatapp-cache-sg` (session 07). No Multi-AZ/replication — deliberate cost
  call, same tone as the single-NAT-Gateway tradeoff above: this backs a rate-limit counter and a
  refresh-token blacklist, not data worth paying for HA on. Endpoint:
  `chatapp-redis.ojv1ik.0001.use1.cache.amazonaws.com:6379`. Wired into the backend as
  `REDIS_URL=redis://<endpoint>:6379/0`, a plain (non-secret) task-definition environment entry —
  an in-VPC endpoint isn't sensitive the way a DB connection string is. Backend redeployed on
  `chatapp-backend` task-definition revision 2. Provisioned by
  `infra/aws-cli-scripts/09-elasticache.sh` + `09b-redis-deploy.sh`.
- **Secrets Manager (session 08, live)**: `chatapp/mongodb-uri`, `chatapp/jwt-secret`,
  `chatapp/openai-api-key`, `chatapp/openai-base-url` — four, not three; `OPENAI_BASE_URL` is
  required too since this project uses a non-OpenAI gateway. Referenced by ARN in the backend
  task definition (`infra/aws-cli-scripts/07-task-defs.sh`) so secrets never appear in the image,
  task def JSON in git, or GitHub Actions logs. `FRONTEND_ORIGIN`/`S3_BUCKET`/`AWS_REGION` are
  plain (non-secret) task-definition environment entries, not Secrets Manager entries. Session 10
  added a fifth secret, `chatapp/grafana-admin-password` — a random string generated by
  `10-grafana-ecs.sh` (`openssl rand`), never written to any file in this repo, injected into the
  Grafana task definition as `GF_SECURITY_ADMIN_PASSWORD`.
- **CloudWatch (session 08/09, live)**: log groups `/ecs/chatapp-backend`/`/ecs/chatapp-frontend`/
  `/ecs/chatapp-grafana` (the last one added session 10) exist and are receiving real logs.
  Container Insights enabled on `chatapp-cluster` (session 09,
  `infra/aws-cli-scripts/09c-cloudwatch.sh`). Seven alarms wired to SNS topic `chatapp-alerts`
  (email subscription `ankitmarwaha7@gmail.com`, same address as the session-06 budget alarm —
  **needs the same one-time confirmation click**): running-task-count-below-desired and CPU/memory
  > 80% for both `chatapp-backend`/`chatapp-frontend`, plus an ALB target 5xx-rate alarm (metric
  math, > 5% over 5 minutes). All in `OK` state as of session 09.
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
  Container-Insights-level panels are wired up and, now that session 09 has landed Redis and
  Container Insights, should be populating too (dimensions worth a quick spot-check next time
  the dashboard is opened — see `docs/sessions/10-grafana-fargate.md`'s note about the
  `CacheClusterId` dimension being a placeholder guess made before session 09's node existed).
  A fourth row, "Application", was added as a follow-up (not part of sessions 09/10's original
  scope — see `app/core/metrics.py` below): request rate/duration/errors, LLM call
  duration/count/success-rate by model, LLM token usage, chat messages sent, file uploads by
  kind, all reading the `ChatApp` CloudWatch namespace.
- **Application metrics (`app/core/metrics.py`)**: request/LLM/chat-message/file-upload metrics
  via CloudWatch Embedded Metric Format (EMF) — distinct from everything above, which describes
  the *containers* (CPU/memory/ALB/cache), not the *application*. A `MetricsLogger` writes a
  specially-shaped JSON line to stdout per call; CloudWatch automatically extracts real metrics
  from it via the same `awslogs` log driver every container already uses — no separate metrics
  API client, no background flush task, no flush-on-shutdown race. `AWS_EMF_ENVIRONMENT` is
  forced to `"local"` in code (not left to auto-detection, which tries an EC2-metadata probe
  Fargate blocks) since stdout is always the right sink here — confirmed necessary by a real
  test failure during development (metrics silently dropped trying to reach a nonexistent
  CloudWatch agent socket without it). `Success` on LLM-call metrics is a real dimension
  (`"true"`/`"false"` string), not just a log property, so failure rate is directly chartable.
  Wired into the request-metrics middleware (`app/main.py`, skips `/health` — ALB polling noise,
  not application traffic) and instrumented directly in `messages.py` (chat message count, LLM
  call duration/tokens — more accurate than the generic request-duration metric for the
  streaming chat endpoint, since `StreamingResponse` returns before its generator actually runs)
  and `files.py` (upload count/size by kind).
- **HTTPS/domain**: intentionally deferred (session 12). Until then everything is served over
  HTTP on the ALB's own `*.elb.amazonaws.com` DNS name — acceptable for early iteration, not
  for real user traffic with credentials, so treat pre-session-12 deployments as staging-only.

## CI/CD (session 11, live)

- Two workflows, both in `.github/workflows/`:
  - `ci.yml` — on every pull request: backend tests (`pytest`, Python 3.12, no AWS/DB
    credentials needed — the test suite runs entirely against `mongomock-motor`/`fakeredis`, see
    `backend/tests/conftest.py`) and frontend lint + build (`npm run lint`, `npm run build`, Node
    22). No AWS credentials configured in this workflow at all — the deploy role's OIDC trust
    policy only allows assumption from pushes to `main` anyway, so a PR-triggered run couldn't
    assume it even if it tried.
  - `deploy.yml` — on every push to `main`: builds and pushes all three Docker images (backend,
    frontend, grafana) to ECR tagged with the commit SHA, then for each service: fetches the
    current task definition (`aws ecs describe-task-definition`), patches only that container's
    `image` field via `jq`, strips the fields `register-task-definition` rejects
    (`taskDefinitionArn`/`revision`/`status`/`requiresAttributes`/`compatibilities`/
    `registeredAt`/`registeredBy`), registers the new revision, and force-deploys it
    (`aws ecs update-service --force-new-deployment`). Waits for all three services to stabilize,
    then curls `/health`, `/login`, `/grafana/api/health` on the live ALB DNS name as a final
    smoke test. This is the exact fetch→patch→register→force-deploy→wait pattern sessions 08-10's
    `07-task-defs.sh`/`08-ecs-services.sh`/`09b-redis-deploy.sh`/`10-grafana-ecs.sh` established
    manually — session 11 just automates it.
- AWS auth via GitHub's OIDC provider (`aws-actions/configure-aws-credentials`) assuming
  `chatapp-github-deploy` (session 06) — no long-lived AWS access keys stored as GitHub secrets.
  `permissions: id-token: write` + `contents: read` set at the workflow level (required for OIDC
  role assumption to work at all — silently fails as a runtime permissions error otherwise, not a
  workflow-syntax error). The role's existing scope (ECR push to `chatapp-*` repos; ECS
  `DescribeServices`/`DescribeTaskDefinition`/`RegisterTaskDefinition`/`UpdateService`;
  `iam:PassRole` scoped to `chatapp-*` roles) needed no changes — verified sufficient on the first
  real run.
- Resource identifiers the workflow needs (account id, ECR registry, cluster/family/service names,
  ALB DNS name) are hardcoded as workflow-level `env:` in `deploy.yml`, copied from
  `infra/aws-cli-scripts/.env.aws` (gitignored, so unavailable to the Actions runner) — none of
  these are secrets, they're the same resource identifiers already visible in every
  `infra/aws-cli-scripts/*.sh` script.
- **Verified live (2026-07-08)**: the commit that added `deploy.yml` triggered a real deployment
  end to end — all three services moved to new task-definition revisions
  (`chatapp-backend:2→3`, `chatapp-frontend:1→2`, `chatapp-grafana:2→3`), all three running images
  tagged with that commit's SHA, `runningCount == desiredCount == 1` for all three, ALB health
  checks (`/health`, `/login`, `/grafana/api/health`) all `200` post-deploy, and a real signup +
  LLM chat message round-tripped successfully through the freshly redeployed backend (test data
  cleaned up from Atlas afterward, same pattern as sessions 01/02/08/09).
- **Known gap**: `ci.yml`'s failure behavior was verified by pushing a deliberately broken test to
  a throwaway branch (`ci-broken-test`) and confirming `pytest` fails on it (`1 failed, 36
  passed`) — the exact command the CI job runs — but an actual GitHub Pull Request object was
  never opened to prove the `pull_request`-triggered workflow run itself goes red, because doing
  so needs a write-scoped GitHub API call and this machine has no `gh` CLI installed/authenticated
  and no `GITHUB_TOKEN`; extracting the git-credential-manager token cached for `git push` to use
  for that API call was (correctly) refused as credential exfiltration outside its intended git-only
  use. The throwaway branch was pushed, then deleted (both remote and local) without merging,
  consistent with the done-criteria's spirit even though the literal PR object was never created.
  If this matters for a future session, install/authenticate the `gh` CLI once
  (`gh auth login`) so this check can be closed properly.

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
