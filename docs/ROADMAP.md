# Roadmap

**Live since session 08**: http://chatapp-alb-811403579.us-east-1.elb.amazonaws.com (HTTP only —
custom domain/HTTPS is session 12).

This project is deliberately split into isolated, focused sessions so no single Claude Code
session has to carry the whole build in its context window. Each session has a brief at
`docs/sessions/NN-name.md` that is self-contained: a fresh session (or a parallel one running in
a separate git worktree) should be able to read that one file plus `docs/ARCHITECTURE.md` and
start working without needing this conversation's history.

**How to use this file**: check a box when a session's "done criteria" (in its brief) are met.
Update `docs/ARCHITECTURE.md` if a session changes a decision made there.

**Running sessions in parallel**: sessions that don't touch overlapping files (e.g. session 1
"Backend core" and session 3 "Frontend core") can run concurrently in separate git worktrees.
Sessions with a hard dependency (e.g. session 8 needs session 7's VPC/ECR to exist) must run
sequentially.

## Sessions

- [x] 00 — Foundations & scaffolding
- [x] 01 — Backend core (auth + conversation/message CRUD)
- [x] 02 — Backend LLM + files (OpenAI streaming, file upload/parse/download)
- [x] 03 — Frontend core (scaffold, auth pages, protected layout, basic chat)
- [x] 04 — Frontend chat experience (streaming, file previews/downloads, markdown)
- [x] 05 — Dockerization & local end-to-end
- [x] 06 — AWS account bootstrap (CLI install, IAM user, OIDC role, budget alarm)
- [x] 07 — AWS networking + ECR (VPC, subnets, NAT, security groups, ECR repos)
- [x] 08 — AWS compute + ALB (ECS cluster, task defs, services, load balancer, Secrets Manager)
- [x] 09 — ElastiCache + CloudWatch (Redis, log groups, Container Insights, alarms)
- [x] 10 — Grafana on Fargate (config-as-code dashboards over CloudWatch)
- [x] 11 — CI/CD via GitHub Actions (OIDC, build/push/deploy pipeline)
- [ ] 12 — HTTPS/custom domain (deferred until a domain is available)

## Post-roadmap follow-ups

Work outside the original 12-session structure, addressing gaps found after the fact rather than
scheduled sessions:

- **Application-level metrics** (2026-07-08) — the original request asked for metrics "with
  respect to an application and with respect to a server"; sessions 09/10 only built the server
  half (ECS/ALB/ElastiCache via CloudWatch+Grafana). Added request/LLM/chat-message/file-upload
  metrics via CloudWatch EMF, wired into the same Grafana dashboard as a new "Application" row.
  See `docs/ARCHITECTURE.md`'s "Application metrics" entry and `backend/app/core/metrics.py`.
- **FastAPI lifespan** (2026-07-08) — `app/main.py` never had one; added graceful Mongo/Redis
  shutdown and explicit (not import-time-side-effect) connection setup. See `docs/ARCHITECTURE.md`'s
  Backend section, "Lifespan" entry.
- **Structured application logging** (2026-07-08) — a second gap in the same original request as
  the metrics one above ("log each and everything... inside CloudWatch"): the backend had
  essentially no application-level logging (2 exception handlers total). Added structured JSON
  logging for every request and every user-facing action, with `user_id` context. ALB S3 access
  logs were considered as a companion fix but deliberately skipped — they land in S3, not
  CloudWatch, so they don't match the literal ask. See `docs/ARCHITECTURE.md`'s "Structured
  logging" entry and `backend/app/core/logging_config.py`.
- **Production-readiness audit** (2026-07-08) — prompted by the same pattern as the lifespan gap:
  asked to proactively find any other missed production-grade practices rather than wait for them
  to be reported one at a time. Found and fixed: no DB indexes + a TOCTOU signup race
  (`DuplicateKeyError` now caught, indexes created via `backend/scripts/ensure_indexes.py`), no
  rate limiting on `/auth/signup`/`/auth/login` (added, keyed by client IP via `X-Forwarded-For`),
  unbounded file-upload reads before the size check (now bounded), `deploy.yml` deploying without
  running tests first (now gated on `backend-tests`/`frontend-checks`), no global exception
  handler (added — required folding it into the existing `BaseHTTPMiddleware` instead of a
  separate `@app.exception_handler`, since that combination is a known Starlette/FastAPI gap),
  unbounded list endpoints (`GET /conversations`, `GET /conversations/{id}/messages` now capped),
  loose (`>=`) dependency pins (now exact), no LLM request timeout, no frontend error boundary,
  and no ECS deployment circuit breaker (added, live-applied to all three services). Multi-
  instance redundancy (`desiredCount` > 1) was surfaced but deliberately deferred — real ongoing
  AWS cost for a project not yet at that scale. See `docs/ARCHITECTURE.md`'s "Production-
  readiness audit" entry.
- **LLM client eager-init crash** (2026-07-08) — a follow-up bug the audit's own test-gating fix
  (above) exposed: `deploy.yml` had never actually run backend tests before (no gate existed, and
  `ci.yml` only triggers on pull requests, which this repo doesn't use), so this was the first
  time pytest ran in a truly clean environment. `app/services/llm.py` built its `AsyncOpenAI`
  client at *import* time; without a real `OPENAI_API_KEY` (no `.env`, as in CI) this raises
  `OpenAIError` during `import app.main`, failing pytest collection entirely — reproduced exactly
  via a from-scratch `python:3.12-slim` container with no `.env`. Fixed by building the client
  lazily (`functools.lru_cache`-wrapped `_get_client()`), matching the same "no import-time I/O
  or side effects" principle already applied to `app/core/db.py`.

## Dependency order

```
00 ──┬──> 01 ──> 02 ──┐
     └──> 03 ──> 04 ──┴──> 05 ──> 06 ──> 07 ──> 08 ──┬──> 09 ──> 10
                                                       └──> 11 ──> 12
```

01/02 (backend) and 03/04 (frontend) can be built in parallel worktrees once 00 is merged; both
must land before 05 (needs both Dockerfiles). 06 is a hard gate for everything AWS. 09, 10, 11
can happen in any order once 08 is live; 12 needs a purchased/available domain.
