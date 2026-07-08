# Build Playbook — a production ChatGPT clone, end to end

> **This is a portable playbook, not a repo-specific config file.** It's written to be lifted into
> a *new* project when you want to build something architecturally similar (LLM chat app + FastAPI +
> Next.js + AWS ECS). Copy this file into the new repo, or hand it to a fresh Claude Code session
> with "build me something like this." For day-to-day work on *this* repo, see the lean `CLAUDE.md`
> at the root (auto-loaded every session) — it points here for the deep material.

This file is the map of an entire, real, live-deployed project: a multi-user ChatGPT-style web app
with text/image/document chat, built with a Next.js frontend and FastAPI backend, deployed on AWS
(ECS Fargate, ALB, ElastiCache, CloudWatch, self-hosted Grafana), with GitHub Actions CI/CD
authenticating to AWS via OIDC (no stored keys). It was built session-by-session in isolated Claude
Code conversations, each scoped small enough to fit in one context window, then hardened by a
production-readiness audit after the fact.

**Use this file to rebuild a similar project from scratch.** It documents not just what was built,
but *why*, in what order, and every non-obvious mistake made along the way — the gotchas section
(section 11) is the highest-value part; most of it cost a real debugging session to discover.

Deeper reference for *this specific* project (won't travel to a new repo, listed here for
in-project use):
- `docs/ARCHITECTURE.md` — the full, current system design (longer and more detailed than this file)
- `docs/ROADMAP.md` — session checklist, dependency graph, post-roadmap follow-ups
- `docs/sessions/NN-name.md` — one self-contained brief per build session
- `infra/aws-cli-scripts/README.md` — AWS CLI gotchas specific to the dev machine

---

## 1. What this app actually does

- Multi-user, email/password auth (JWT access + refresh tokens in httpOnly cookies, bcrypt hashing).
- Chat conversations with an LLM, streamed token-by-token over SSE.
- File attachments: images go to the LLM as vision input; PDF/Word/Excel get server-side text
  extraction injected into the prompt (context-stuffing, not RAG). Files are viewable inline and
  downloadable from the chat thread.
- Every conversation is scoped to its owning user; no cross-user access.
- Fully deployed to AWS with CI/CD: push to `main` → tests gate → build → push to ECR → redeploy
  ECS services → live health-check verification.
- Full observability: structured JSON logs and custom application metrics in CloudWatch, server
  metrics (ECS/ALB/ElastiCache) via Container Insights, all visualized in a self-hosted Grafana
  dashboard.

## 2. Tech stack, and why each piece was chosen

| Layer | Choice | Why |
|---|---|---|
| Frontend | Next.js (App Router) + TypeScript + Tailwind | SSR-capable React framework with a built-in route-gate mechanism (`proxy.ts`, formerly `middleware.ts`) that can inspect cookies server-side without a separate BFF. |
| Backend | FastAPI + Python 3.12 | Native `async def` + SSE streaming support, Pydantic validation, OpenAPI docs for free. |
| DB driver | Motor (async MongoDB) | Matches FastAPI's async model; no thread-pool wrapping needed. |
| Database | MongoDB Atlas | Managed, cloud-hosted, same connection string in dev and prod — no local Mongo container needed. |
| Auth | JWT access+refresh in httpOnly cookies | XSS-resistant (JS can't read the cookie); refresh token tracked in Redis so logout is real revocation, not just "hope the client forgets the token." |
| Cache/session store | Redis (ElastiCache in prod) | Two narrow jobs only — rate-limit counters (`INCR`/`EXPIRE`) and refresh-token blacklist (`SET ... EX`) — never used as a generic response cache. Falls back to in-memory `fakeredis` locally when `REDIS_URL` is unset, so no local Redis install is required for dev. |
| LLM | OpenAI SDK pointed at a third-party OpenAI-*compatible* gateway via `base_url=` | The official `openai` Python SDK supports arbitrary compatible endpoints natively; no need for a custom HTTP client. Verify streaming/vision/token-usage behavior against *your* gateway before assuming OpenAI's docs apply verbatim — this project's gateway diverges in places (see gotchas). |
| File storage | Storage-abstraction interface, local-disk (dev) / S3 (prod) | Fargate containers have no persistent shared disk — S3 isn't optional in production, it's a hard requirement once you're off a single VM. |
| Compute | ECS Fargate | No EC2 instances to patch/manage; pay per task, not per always-on server. |
| Load balancing | Application Load Balancer, path-based routing | One DNS name for frontend + backend + Grafana, routed by path prefix — avoids needing three separate domains/subdomains before a custom domain even exists. |
| Container registry | ECR | Native IAM-integrated registry; no extra credentials needed beyond the same OIDC role. |
| Secrets | AWS Secrets Manager, `valueFrom` in ECS task defs | Secrets are resolved into the container's env by the ECS execution role at container-start time — never touch the image, the task-def JSON in git, or CI logs. |
| Observability | CloudWatch (logs, EMF custom metrics, alarms) + self-hosted Grafana on Fargate | Structured JSON logs and EMF metrics both ride the same `awslogs` log driver every container already has — no separate metrics pipeline to build or pay for. Grafana self-hosted (not Amazon Managed Grafana) because it's config-as-code (dashboards baked into the image) and free beyond the tiny Fargate task cost. |
| CI/CD | GitHub Actions, OIDC to AWS | No long-lived AWS access keys stored anywhere in GitHub — a short-lived STS credential is minted per workflow run, scoped by IAM trust policy to the exact repo+branch. |

## 3. Architecture at a glance

```
Browser
  │  HTTP (cookies: access_token, refresh_token — httpOnly)
  ▼
ALB (one DNS name, path-based routing)
  ├─ /auth*, /conversations*, /health, /docs, /openapi.json  → backend target group
  ├─ /grafana*                                                → grafana target group
  └─ everything else (default)                                → frontend target group
        │                    │                          │
        ▼                    ▼                          ▼
  ECS Fargate:          ECS Fargate:               ECS Fargate:
  chatapp-backend       chatapp-frontend            chatapp-grafana
  (FastAPI, private     (Next.js, private            (self-hosted, private
   subnet, no public     subnet, no public             subnet, CloudWatch
   IP)                   IP)                            datasource, no
     │                                                   static AWS keys)
     ├──> MongoDB Atlas (all app data)
     ├──> ElastiCache Redis (rate limits, refresh-token blacklist)
     ├──> S3 (file attachment bytes)
     ├──> Secrets Manager (DB URI, JWT secret, LLM key — injected at container start)
     └──> LLM gateway (OpenAI-compatible, streaming + vision)

CloudWatch: structured JSON logs + EMF app metrics + Container Insights + 7 alarms → SNS → email
GitHub Actions (OIDC, no stored keys) → build/push ECR → register task def → force-deploy ECS
```

## 4. Repo layout

```
/frontend                    Next.js App Router, TypeScript, Tailwind
/backend                     FastAPI, Python 3.12
  /app
    main.py                  app factory, lifespan, observability middleware
    /core                    config, db, redis, security (JWT/bcrypt), rate_limit,
                              token_blacklist, logging_config, metrics, serialization
    /models                  Pydantic request/response schemas (user, conversation, message, file)
    /routers                 auth, conversations, messages, files
    /services                llm.py (OpenAI-compatible client), storage.py (disk/S3), extract.py
  /scripts                   ensure_indexes.py — standalone, manually-run, idempotent
  /tests                     pytest, mongomock-motor + fakeredis (no real infra needed)
/infra
  /aws-cli-scripts           numbered *.sh, one AWS concern each, idempotent, + setup-all.ps1
                              (PowerShell orchestrator) + 99-cleanup.sh (full teardown)
  /docker                    Dockerfiles (multi-stage, non-root), docker-compose.yml, Grafana
                              provisioning (config-as-code datasource + dashboards)
/docs
  ARCHITECTURE.md            full system design — the deep-dive counterpart to this file
  ROADMAP.md                 session checklist + dependency graph + post-roadmap follow-ups
  /sessions/NN-name.md       one self-contained brief per build session
.github/workflows/
  ci.yml                     pull_request: backend tests + frontend lint/build, no AWS access
  deploy.yml                 push to main: test-gated build → push → deploy → live health-check
```

## 5. Code flow walkthroughs

### Auth flow

1. `POST /auth/signup` — Pydantic validates (`UserSignup`: email, 8+ char password, name), bcrypt
   hashes the password, inserts into `users`. A pre-check `find_one` catches most duplicate emails
   fast, but the **real** guarantee is a unique index on `users.email` plus a caught
   `pymongo.errors.DuplicateKeyError` around the insert — the pre-check alone has a TOCTOU race
   between two concurrent signups with the same email.
2. `POST /auth/login` — verifies bcrypt hash, issues an access token (short-lived, e.g. 15 min) and
   a refresh token (long-lived, e.g. 7 days), both JWTs signed with `JWT_SECRET`, set as separate
   httpOnly/secure/SameSite cookies (`access_token`, `refresh_token`).
3. Every protected route depends on `get_current_user` (`app/dependencies.py`): reads the
   `access_token` cookie via FastAPI's `Cookie(default=None)`, decodes+validates the JWT, loads the
   user from Mongo by the token's subject claim. No cookie / invalid / expired / user-deleted → 401.
4. `POST /auth/refresh` — reads the `refresh_token` cookie, checks it's not blacklisted in Redis
   (`app/core/token_blacklist.py`), issues a new access token.
5. `POST /auth/logout` — blacklists the current refresh token in Redis (`SET key EX <remaining
   TTL>`) and clears both cookies. This is what makes logout a *real* revocation instead of just
   "the client stopped sending the cookie" — a stolen pre-logout refresh token gets rejected by
   step 4's blacklist check.
6. Frontend route gate is **two-layer**, because httpOnly cookies can't be read by client JS:
   - `frontend/src/proxy.ts` (Next.js middleware, runs server-side, sees the raw `Cookie` header)
     checks only whether the `access_token` cookie is *present* — not whether the JWT is valid.
     Missing → redirect to `/login`. This is cheap and has no failure mode worth avoiding.
   - `AuthContext` (`frontend/src/contexts/AuthContext.tsx`) is the authoritative check: calls
     `GET /auth/me` on mount, treats any 401 as unauthenticated and redirects client-side. This is
     what catches a *present but expired/invalid* cookie that proxy's presence-only check can't.
   - Deliberately did **not** validate the JWT signature inside `proxy.ts` — that would mean
     duplicating `JWT_SECRET` into frontend code (an unwanted trust-boundary leak) for marginal
     benefit over the real check in step 2.

### Chat message flow (the core feature)

1. Frontend `POST /conversations/{id}/messages` with `{content, file_ids}`.
2. Backend validates the conversation belongs to the current user (404, not 403, if not — avoids
   leaking existence of other users' conversation IDs).
3. Persists the user's message immediately, including resolved file attachment summaries.
4. Response is `text/event-stream`, HTTP 200 (not 201 — it's a stream, not a single created
   resource), with a small custom SSE protocol:
   - `event: user_message` — fired immediately, so the client has the persisted user message's
     real id before any tokens arrive (lets the UI render it right away, not just optimistically).
   - `event: token` × N — incremental text deltas from the LLM's streaming response.
   - `event: error` — only if the LLM call fails; the endpoint still returns 200 and a graceful
     fallback message rather than blowing up the whole response mid-stream.
   - `event: done` — final event, carries the persisted assistant message.
5. Server-side, `app/services/llm.py`'s `stream_chat_completion()` wraps the OpenAI SDK's
   `chat.completions.create(stream=True, stream_options={"include_usage": True})`, yielding text
   deltas and invoking an `on_usage` callback once real token counts arrive — used to record LLM
   token metrics without a second round trip.
6. Image attachments become `image_url` content parts (base64 data URI) if `settings.vision_supported`;
   PDF/Word/Excel attachments have their server-extracted text appended directly into the prompt
   text (truncated to `extracted_text_max_chars`) — an MVP context-stuffing design, explicitly not
   RAG/embeddings.
7. The OpenAI client itself is built **lazily** (`functools.lru_cache`-wrapped `_get_client()`),
   not at module import time — see the gotchas section for why that distinction is load-bearing.

### File upload/download flow

1. `POST /conversations/{id}/files` — multipart upload. Reads at most `max_upload_size_mb + 1`
   bytes (bounded read *before* the size check can even matter — reading the whole body first and
   rejecting after doesn't actually bound memory use).
2. Kind is inferred from mimetype (`image`/`pdf`/`docx`/`xlsx`/`other`); documents get server-side
   text extraction (pdfplumber/python-docx/openpyxl) into a preview string.
3. Bytes go to the storage backend (`app/services/storage.py`) — local disk in dev, S3 in prod, via
   one abstraction interface so route code never branches on environment. Mongo stores only
   metadata (filename, storage key, mimetype, size, extracted-text preview) — never raw bytes.
4. Download: prod redirects (307) to a presigned S3 URL rather than proxying bytes through the
   backend; dev streams the file directly off disk.

## 6. Data model (MongoDB Atlas)

| Collection | Key fields | Indexes |
|---|---|---|
| `users` | email, hashed_password, name, created_at | unique on `email` |
| `conversations` | user_id, title, created_at, updated_at | compound `(user_id, updated_at desc)` |
| `messages` | conversation_id, role, content, attachments[], created_at | compound `(conversation_id, created_at asc)` |
| `files` | conversation_id, user_id, filename, storage_key, mimetype, kind, size, extracted_text_preview, created_at | `(conversation_id)`, `(user_id)` |

Indexes are created by a **standalone, manually-run** script (`backend/scripts/ensure_indexes.py`),
deliberately **not** called from the app's `lifespan` — every container replica racing to create
indexes on every cold start/redeploy is worse than a one-time operational step.

List endpoints (`GET /conversations`, `GET /conversations/{id}/messages`) are capped
(`max_conversations_returned`, `max_messages_returned` — generous defaults, a backstop not a
UX-facing pagination scheme). The messages cap needed care: naively `.limit()`-ing an
ascending-sorted query keeps the *oldest* N messages, silently freezing a long conversation's
visible history at its beginning once it exceeds the cap — the fix sorts descending, limits, then
reverses in Python to keep the most-recent N in correct chronological order.

## 7. AWS infrastructure (condensed — see `docs/ARCHITECTURE.md` for full detail)

- **VPC**: `10.0.0.0/16`, public+private subnets across 2 AZs, one NAT Gateway (not one per AZ —
  deliberate cost tradeoff). Security groups form a strict chain: ALB SG (open to internet) → ECS
  SG (only from ALB SG) → Cache SG (only from ECS SG). Nothing but the ALB is internet-reachable.
- **ECS Fargate**: cluster with three services (`chatapp-backend`, `chatapp-frontend`,
  `chatapp-grafana`), `desiredCount: 1` each (smallest task size, 256 CPU/512MB — deliberate cost
  control), private subnets, no public IPs. Deployment circuit breaker enabled (auto-rollback on a
  bad task definition) on all three.
- **ALB**: one DNS name, path-based routing (see architecture diagram above). Health checks matter:
  frontend's is `/login` not `/`, because `/` 307-redirects unauthenticated requests and the ALB's
  default health-check matcher only accepts 200.
- **ECR**: one repo per service, scan-on-push enabled.
- **S3**: private bucket, all public access blocked, default encryption — file attachment storage.
- **ElastiCache**: single-node Redis (`cache.t3.micro`, no Multi-AZ) — deliberate cost call; this
  backs a rate-limit counter and a token blacklist, not data worth paying for HA on.
- **Secrets Manager**: `mongodb-uri`, `jwt-secret`, `openai-api-key`, `openai-base-url`,
  `grafana-admin-password` — all referenced by ARN in ECS task defs (`valueFrom`), resolved into
  the container's environment by the ECS execution role at container-start time.
- **CloudWatch**: per-service log groups, Container Insights, 7 alarms (task-count-below-desired
  and CPU/memory >80% per service, plus ALB 5xx-rate) wired to an SNS topic with an email
  subscription (needs a one-time confirmation click).
- **Grafana**: self-hosted on Fargate, config-as-code (datasource + dashboards baked into the image
  at build time — stateless, no EFS volume). CloudWatch datasource auth is via its own task role
  (`chatapp-grafana-task-role`, read-only `GetMetricData`/`ListMetrics`/`DescribeAlarms`), no static
  AWS keys. Served at `/grafana` via the ALB, `GF_SERVER_SERVE_FROM_SUB_PATH=true` since the ALB
  forwards the request path unmodified rather than stripping the prefix.
- **Application metrics** (`app/core/metrics.py`): CloudWatch Embedded Metric Format (EMF) — a
  specially-shaped JSON log line per call, extracted into real metrics by CloudWatch automatically
  via the same log driver every container already uses. No separate metrics API client, no
  background flush task. This is distinct from (and a deliberate addition alongside) the
  server-level ECS/ALB/cache metrics above — "metrics with respect to an application AND with
  respect to a server" was the actual original ask, and building only the server half was an
  early gap this project's audit caught and fixed.

## 8. CI/CD

- `ci.yml` (pull_request): backend `pytest` + frontend `npm run lint`/`npm run build`. No AWS
  credentials configured at all — not needed, and the deploy role's OIDC trust policy only allows
  assumption from pushes to `main` anyway.
- `deploy.yml` (push to `main`): **first** runs `backend-tests`/`frontend-checks` jobs (mirroring
  `ci.yml`), and the actual deploy job `needs: [backend-tests, frontend-checks]` — a broken commit
  never reaches production. Then: build+push all three Docker images to ECR tagged with the commit
  SHA → for each service, fetch its current task definition, patch only that container's `image`
  field via `jq`, strip the fields `register-task-definition` rejects, register a new revision,
  `update-service --force-new-deployment` → wait for all three services to stabilize → curl
  `/health`, `/login`, `/grafana/api/health` on the live ALB as a final smoke test.
- **Auth**: GitHub's OIDC provider, registered once in AWS, trusted by an IAM role
  (`chatapp-github-deploy`) whose trust policy restricts assumption to
  `repo:<org>/<repo>:ref:refs/heads/main`. Each workflow run gets a short-lived STS credential —
  nothing long-lived is ever stored as a GitHub secret. `permissions: id-token: write` is required
  at the workflow level for this to work at all (fails silently as a runtime permissions error
  otherwise, not a workflow-syntax error).
- **Rollback**: every deploy registers a new task-def revision under the same family; old revisions
  aren't deleted. Rolling back is just `aws ecs update-service --task-definition <family>:<old-rev>
  --force-new-deployment` — no rebuild needed. See root `README.md` for the exact commands.

## 9. How to build this from scratch — the session recipe

This was built as 12 sequential/parallel sessions, each small enough to fit one Claude Code context
window, each with a self-contained brief at `docs/sessions/NN-name.md`. This order is the actual
dependency graph, not an arbitrary checklist — follow it if rebuilding something similar:

```
00 ──┬──> 01 ──> 02 ──┐
     └──> 03 ──> 04 ──┴──> 05 ──> 06 ──> 07 ──> 08 ──┬──> 09 ──> 10
                                                       └──> 11 ──> 12
```

0. **Foundations & scaffolding** — monorepo skeleton, docs structure, `.env.example`, empty
   docker-compose. No business logic, no AWS.
1. **Backend core** — FastAPI app, Mongo connection, JWT auth (signup/login/refresh/logout),
   conversation/message CRUD, pytest setup with `mongomock-motor`.
2. **Backend LLM + files** — streaming OpenAI-compatible chat endpoint (verify your actual gateway's
   behavior live before assuming vanilla OpenAI docs apply), file upload/parse/download, storage
   abstraction (disk dev / S3 prod stub).
3. **Frontend core** — scaffold, Tailwind, auth pages, protected layout via the route-gate pattern,
   sidebar + basic (non-streaming) chat wired to the real backend. *(Can run in parallel with 1/2
   in a separate git worktree — no overlapping files.)*
4. **Frontend chat experience** — SSE token-by-token streaming UI, file attach + inline previews +
   download with progress, markdown/code rendering, loading/error/retry states.
5. **Dockerization & local e2e** — multi-stage Dockerfiles (non-root, no baked secrets), full
   docker-compose stack, verify chat + file upload/download end-to-end locally against real Atlas.
6. **AWS account bootstrap** — CLI setup, scoped IAM user, GitHub OIDC provider + deploy role,
   budget alarm. Mostly manual/console-guided, not fully scriptable (OIDC thumbprint needs a live
   TLS handshake).
7. **AWS networking + ECR** — VPC/subnets/NAT/security groups, ECR repos, push a manual test image.
8. **AWS compute + ALB** — ECS cluster, task defs, services, ALB/target groups/listener rules,
   Secrets Manager, S3 bucket, first manual CLI deploy proving the path end-to-end.
9. **ElastiCache + CloudWatch** — Redis wired into rate-limiting/session logic, log groups,
   Container Insights, baseline alarms.
10. **Grafana on Fargate** — config-as-code dashboards over the CloudWatch datasource, routed
    through the ALB.
11. **CI/CD** — GitHub Actions OIDC auth, test-gated build/push/deploy pipeline, rollback notes.
12. **HTTPS/custom domain** — deferred until a domain is actually available; Route53 + ACM + ALB
    HTTPS listener.

**After the 12 sessions**: a **production-readiness audit** pass caught real gaps the incremental
build missed — see section 10 below and `docs/ROADMAP.md`'s "Post-roadmap follow-ups". Budget for
this as a real, separate phase; it is not optional polish. Things like "no rate limiting on the
auth endpoints" or "no global exception handler" are exactly the kind of gap that's invisible while
building happy-path features and only surfaces under adversarial or unlucky conditions.

## 10. Operational scripts

- `infra/aws-cli-scripts/00-*.sh` through `10-*.sh` — numbered, idempotent, one AWS concern each.
  Each writes the resource IDs it creates to `.env.aws` (gitignored) so later scripts can reference
  them without re-querying the AWS API. Every script starts with
  `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` — see gotchas.
- `infra/aws-cli-scripts/setup-all.ps1` — thin PowerShell orchestrator that runs all the numbered
  scripts in order via Git Bash. Does not reimplement their logic (avoids drift from what's
  actually running in prod). Supports `-DryRun`, `-From <prefix>` (resume after a fix),
  `-Only <prefix>` (re-run one script). Verifies AWS identity before touching anything.
- `infra/aws-cli-scripts/99-cleanup.sh` — full reverse-order teardown of everything the numbered
  scripts create, to stop all billing. Requires typing the project name to confirm. `--dry-run`
  lists what would be deleted without deleting. Keeps the free-tier IAM/OIDC/budget resources by
  default (`--include-account-bootstrap` to remove those too — makes rebuilding require re-doing
  the manual OIDC thumbprint step).

## 11. Hard-won lessons and gotchas

This is the most valuable section for rebuilding something similar — nearly every entry cost a real
debugging session in this project.

**FastAPI/Starlette**
- `@app.exception_handler(Exception)` **does not fire** when `BaseHTTPMiddleware`-style middleware
  (`@app.middleware("http")`) is also registered — a known Starlette/FastAPI interaction gap,
  confirmed here via a real failing test (the exception propagated straight past the handler). Fix:
  put the try/except directly inside the middleware's `call_next()` call instead of a separate
  exception handler.
- A FastAPI `lifespan` should do graceful connection *shutdown*, but avoid doing connectivity
  *pings* at startup if your test suite runs the real lifespan via `TestClient` per test — a ping
  against an unmocked default connection string can hang for the driver's full server-selection
  timeout (~30s), once per test.
- Build expensive/external clients (OpenAI SDK, etc.) **lazily**, not at module import time.
  Eager construction that requires a real credential (e.g. `AsyncOpenAI(api_key="")` raises
  `OpenAIError` when the key is empty) will crash `pytest` collection outright in any environment
  without that credential configured — including CI, if nothing else already caught this. This bit
  us *because* fixing "no test gate in the deploy pipeline" was itself what first ran the test
  suite in a genuinely clean environment — a fix can expose a previously-invisible bug.
- `filename` is a reserved `logging.LogRecord` attribute name — passing it via
  `extra={"filename": ...}` raises `KeyError` at the `logger.info()` call site, not at format time.

**Testing**
- `caplog` accumulates across the *entire test*, not just inside a `with caplog.at_level()` block —
  an earlier call's log record can leak into a later assertion. Call `caplog.clear()` right before
  the assertion-relevant block.
- `mongomock-motor`'s `AsyncMongoMockClient` supports real unique-index enforcement — use it to
  actually simulate race conditions (e.g. a `DuplicateKeyError` path) rather than mocking the error.

**CloudWatch/EMF**
- Without forcing `AWS_EMF_ENVIRONMENT=local` in code (not left to auto-detection, which tries an
  EC2-metadata probe that Fargate blocks anyway), the EMF library silently drops every metric
  trying to reach a nonexistent local CloudWatch agent socket. Set it via `os.environ.setdefault`
  at the very top of the metrics module, before importing the library.

**Windows-specific (relevant if your dev machine is Windows + Git Bash)**
- MSYS2/Git-Bash auto-converts any CLI argument that looks like a Unix absolute path into a Windows
  path *before* the target program ever sees it — e.g. `--log-group-name "/ecs/backend"` silently
  becomes a `C:\...` path. Fix: `export MSYS_NO_PATHCONV=1` before any such command.
- A machine can have stray `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` environment variables from
  an unidentified source (not in Windows User/Machine env vars, not in shell profile files) that
  silently outrank even an explicit `--profile`/`AWS_PROFILE` — there is no CLI flag to override
  this. Always `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` first, and verify
  identity with `aws sts get-caller-identity` before any stateful call. Note that shell state does
  **not** persist between separate tool invocations in some automation contexts — the `unset` must
  be in the *same* command as the AWS call, not a prior one.
- If WSL is installed on the same machine, a bare `bash.exe`/`Get-Command bash.exe` can resolve to
  a WSL launcher stub (under `System32` or the per-user `WindowsApps` alias) instead of Git Bash,
  failing with a cryptic `execvpe(/bin/bash) failed`. Derive Git Bash's real path from wherever
  `git.exe` actually is, rather than trusting a bare `bash` on PATH.
- PowerShell's `-match`/`-notmatch` operators do **element-wise filtering** on an array, not a
  single boolean — `$multilineArray -notmatch "foo"` does not mean what it looks like it means.
  Join to a single string first if you need a real true/false check.

**AWS/infra**
- ALB target-group health checks must hit a route that actually returns 200 for an unauthenticated
  request — a route that redirects (307) will fail the ALB's default 200-only matcher even though
  the app is perfectly healthy.
- Fargate containers have no persistent/shared disk — file storage that needs to survive across
  requests (in a multi-task or redeployed scenario) must go to S3 (or similar), full stop, not "we
  can optimize this later."
- Fargate task execution role vs. task role are different things with different jobs: execution
  role is what ECS itself uses to pull images/write logs/read Secrets Manager; task role is what
  your application code uses at runtime (e.g. S3 access). Keep them scoped separately and tightly.
- ECS deployment circuit breaker (`deploymentCircuitBreaker={enable=true,rollback=true}`) costs
  nothing extra and auto-rolls-back a bad task definition instead of leaving a service stuck
  redeploying a broken revision indefinitely — enable it by default.
- A Docker named volume's mount point is owned by `root` by default; if the container runs as a
  non-root user (it should), pre-create the directory with correct ownership in the Dockerfile
  before the volume is first mounted, or the first write fails with `PermissionError`.
- `NEXT_PUBLIC_*` env vars are inlined into the client JS bundle at **build** time, not read at
  container runtime — they must be passed as a Docker build `ARG`, not a `docker-compose.yml`
  runtime `environment:` entry (which has no effect on an already-built image).

**Process**
- A production-readiness audit is a distinct phase, not a natural byproduct of feature-building.
  Rate limiting on auth endpoints, DB indexes, upload memory bounds, a global exception handler,
  dependency pinning, and a CI test gate were all *absent* after 11 sessions of otherwise-working
  feature work — none of them block the happy path, which is exactly why they're easy to miss.
- When you fix a real gap (e.g. adding a test gate to the deploy pipeline), consider that the fix
  itself might expose a previously-latent bug that was only hidden because the buggy code path
  never actually ran in a clean environment before. Don't assume a fix is "just" the fix.
- Always verify live, not just via unit tests — several real issues here (the exception-handler/
  middleware interaction, the LLM eager-init crash, transient DNS blips) were only caught by
  actually running the app against real infrastructure, not by code review or mocked tests alone.

## 12. Local development quickstart

```bash
cp .env.example .env    # fill in MONGODB_URI, MONGODB_DB_NAME, JWT_SECRET, OPENAI_API_KEY, OPENAI_BASE_URL
docker compose -f infra/docker/docker-compose.yml up --build
```
Frontend: http://localhost:3000 · Backend: http://localhost:8000/health · Redis is internal-only.
MongoDB is **not** containerized — both Docker and non-Docker local runs hit the real Atlas cluster,
so dev and prod exercise identical data-access code. See root `README.md` for the non-Docker path
and full rollback instructions, and `docs/ARCHITECTURE.md`'s "Local development" section for the
`NEXT_PUBLIC_API_URL` build-time-vs-runtime distinction and other Docker-specific judgment calls.
