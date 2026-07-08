# Session 09 — ElastiCache + CloudWatch

**Status**: done (2026-07-08), run as a background agent in the `session-09-elasticache-cloudwatch`
worktree, in parallel with session 10 (Grafana) in its own worktree — both extend the same live
app without touching each other's files.

**What was built**, all via idempotent scripts in `infra/aws-cli-scripts/`:
- `09-elasticache.sh` — cache subnet group `chatapp-cache-subnet-group` (spans both private
  subnets) + single-node ElastiCache Redis cluster `chatapp-redis` (`cache.t3.micro`, engine
  Redis 7.1, port 6379), using the `chatapp-cache-sg` security group session 07 already scoped to
  6379-from-`chatapp-ecs-sg`-only. Single node, no Multi-AZ/replication — deliberate cost call
  (same tone as session 07's single-NAT-Gateway tradeoff): this is a rate-limit counter + a
  refresh-token blacklist, not data worth paying for HA on. Endpoint:
  `chatapp-redis.ojv1ik.0001.use1.cache.amazonaws.com:6379`, written to `.env.aws` as
  `REDIS_URL=redis://chatapp-redis.ojv1ik.0001.use1.cache.amazonaws.com:6379/0`.
- `09b-redis-deploy.sh` — registered `chatapp-backend` task-definition revision 2 (same container
  def as revision 1, plus `REDIS_URL` as a plain environment entry — an in-VPC endpoint isn't
  sensitive the way a DB connection string is, same reasoning as `FRONTEND_ORIGIN`/`S3_BUCKET`
  already being plain entries there), then `update-service --force-new-deployment` +
  `wait services-stable`. Backend now runs on
  `arn:aws:ecs:us-east-1:788070448326:task-definition/chatapp-backend:2`.
- `09c-cloudwatch.sh` — enabled Container Insights on `chatapp-cluster`
  (`aws ecs update-cluster-settings --settings name=containerInsights,value=enabled`; confirmed via
  `describe-clusters --include SETTINGS`). Created SNS topic `chatapp-alerts`
  (`arn:aws:sns:us-east-1:788070448326:chatapp-alerts`) with an email subscription to
  `ankitmarwaha7@gmail.com` (same address as session 06's budget alarm) — **still needs the
  one-time confirmation click in that inbox**, same as session 06's budget email, this script
  can't do it. Seven alarms, all wired to that topic, all in `OK` state as of this write-up:
  - `chatapp-backend-running-tasks` / `chatapp-frontend-running-tasks` — metric-math
    `DesiredTaskCount - RunningTaskCount > 0` (ECS/ContainerInsights namespace), not a hardcoded
    "< 1", so it stays correct if desired count is ever scaled up.
  - `chatapp-backend-cpu-high` / `chatapp-backend-memory-high` / `chatapp-frontend-cpu-high` /
    `chatapp-frontend-memory-high` — AWS/ECS `CPUUtilization`/`MemoryUtilization` > 80%, average
    over 2×5min periods.
  - `chatapp-alb-5xx-rate-high` — metric-math `HTTPCode_Target_5XX_Count / RequestCount * 100 > 5`
    over the ALB (`AWS/ApplicationELB`), `treat-missing-data notBreaching` so a quiet period
    doesn't false-alarm on a divide-by-zero/no-datapoint.

**Backend code correction found while executing this session** (not just infra — see below):
`app/core/token_blacklist.py` (new) + edits to `app/core/security.py` and
`app/routers/auth.py` — `POST /auth/logout` now actually revokes the refresh token via Redis, not
just clears cookies. Rebuilt and pushed a new backend image (`chatapp-backend:session09-1`) with
this fix and deployed *that* on task-definition revision 2 — `manual-1` (session 08) predates it.
See "Correction" section below for why this was necessary and out of the brief's stated scope.

**Live verification performed**, against the real ALB (not a tunnel/localhost):
1. Signed up a throwaway user (`session09-redis-test@example.com`) directly against
   `http://chatapp-alb-811403579.us-east-1.elb.amazonaws.com/auth/signup` → `201`, captured the
   `refresh_token` cookie. `GET /auth/me` → `200`.
2. `POST /auth/logout` → `204`. Replayed the **pre-logout** refresh token (not the cleared cookie
   jar — a raw `Cookie: refresh_token=<old value>` header) at `POST /auth/refresh` →
   **`401 {"detail":"Token has been revoked"}`**. This is the actual proof Redis is wired, not
   just reachable: a bare-JWT-only logout (what this endpoint did before this session) cannot
   reject a still-cryptographically-valid, not-yet-expired token — only a server-side blacklist
   can.
3. `aws logs filter-log-events` on `/ecs/chatapp-backend` for that time window: the exact request
   sequence appears (`POST /auth/signup 201`, `GET /auth/me 200`, `POST /auth/logout 204`,
   `POST /auth/refresh 401`) with **zero** matches for `redis|Redis|Traceback|ERROR|Error` in the
   same window — i.e., the blacklist set/exists calls against the real ElastiCache endpoint
   succeeded silently, no connection errors. (`redis_client.py` has no explicit "connected"
   log line — the absence of connection errors combined with `REDIS_URL` being set in the task def,
   which is the *only* condition that selects real Redis over the `fakeredis` fallback, is the
   available evidence.)
4. Cleaned up the throwaway user from Atlas via a one-off script against `app.core.db` (mirrors
   sessions 01/02/08's cleanup pattern) — confirmed 1 user deleted, 0 conversations (none created).
5. `aws ecs describe-services` — both `chatapp-backend` and `chatapp-frontend` `ACTIVE`,
   `running == desired == 1`. `aws elbv2 describe-target-health` — frontend target `healthy`;
   backend showed one `healthy` + one transient `draining` (the old revision-1 task being
   deregistered, `Target.DeregistrationInProgress` — expected artifact of the deploy, not a
   problem, confirmed by rechecking a minute later).
6. `aws cloudwatch describe-alarms --alarm-name-prefix chatapp` — all 7 alarms present, all `OK`.
7. `aws ecs describe-clusters --include SETTINGS` — `"settings": [{"name": "containerInsights",
   "value": "enabled"}]`.
8. `git status` before every commit — confirmed `.env.aws` and `backend/.env` never appear
   (both correctly gitignored, verified with `git check-ignore -v`).

**Note on the shared cluster**: `chatapp-cluster` also has a `chatapp-grafana` service (session
10, running concurrently in its own worktree) — Container Insights is a cluster-level setting so
it benefits both sessions' services; nothing else here touches Grafana.

## Goal

Provision the Redis cluster the backend already expects (session 02 built the rate-limit/session
code against `REDIS_URL`) and round out observability beyond the basic log groups from session 08.

## Correction to this brief, found while executing it

The brief stated: *"there's no code change needed on the backend side — this session is pure
infrastructure + redeploying with a new env var"*, based on `redis_client.py` already reading
`REDIS_URL`. That premise held for the **rate limiter** (`app/core/rate_limit.py` — genuinely
provider-agnostic, no change needed), but not for **logout**: reading `app/routers/auth.py` before
touching anything showed `POST /auth/logout` was cookie-clear-only —

```python
# Cookie-clear-only logout. Tokens remain cryptographically valid until they expire on
# their own (short-lived access token) — real server-side revocation via a Redis
# blacklist lands once Redis is wired up in a later session (see docs/ARCHITECTURE.md).
```

— i.e. the blacklist this session's own done-criteria required ("logout actually invalidates the
refresh token") **did not exist yet**, despite `docs/ARCHITECTURE.md`'s "Redis" section already
describing it as if it did ("Refresh tokens are tracked in Redis so logout / revocation actually
works"). Provisioning ElastiCache alone would have made that live-verification step fail, or
worse, silently "pass" for the wrong reason (in a single-backend-task deployment, `fakeredis`'s
in-memory blacklist would satisfy the same test just as well as real Redis would — the two are
only distinguishable by whether `REDIS_URL` is actually set and errors are absent, not by this
functional test in isolation).

Fixed by adding a real Redis-backed blacklist:
- `backend/app/core/security.py` — added `token_ttl_seconds()`: decodes a token (still verifying
  signature, only skipping expiry) and returns its remaining lifetime, or `None` if invalid/already
  expired.
- `backend/app/core/token_blacklist.py` (new) — `blacklist_refresh_token()` /
  `is_refresh_token_blacklisted()`, keyed by a SHA-256 hash of the token (not the raw token, so a
  Redis dump/`SCAN` can't leak a usable credential), entry TTL = the token's own remaining
  lifetime (no point outliving a token that would've expired anyway).
- `backend/app/routers/auth.py` — `logout` now blacklists the refresh token cookie (if present)
  before clearing cookies; `refresh` now checks the blacklist and returns `401 "Token has been
  revoked"` if hit. The short-lived access token is still revoked by cookie-clear + its own 15-min
  expiry only — blacklisting it too would cost a Redis round trip on every authenticated request
  for a token that's already short-lived; not worth it.
- Added `tests/test_auth.py::test_logout_blacklists_refresh_token` (replays a pre-logout refresh
  token via a raw cookie header after logout, asserts `401`) — this is the exact scenario re-run
  live against the real ElastiCache cluster above. Full suite: **36 passed**.
- Rebuilt the backend image (code changed) and pushed it as `chatapp-backend:session09-1` — the
  `manual-1` image from session 08 does not have this fix. `09b-redis-deploy.sh` deploys this tag
  (`BACKEND_IMAGE_TAG`, independent of the `IMAGE_TAG` var the frontend/original backend still
  reference) rather than assuming no rebuild was needed.

## Prerequisites

- Session 08 done (ECS services + VPC/security groups live).

## Deliverables

- `infra/aws-cli-scripts/09-elasticache.sh` — single-node Redis cluster in the private subnet,
  restricted to the ECS task security group.
- Update the backend task definition/secret with the real `REDIS_URL`, redeploy.
- Enable Container Insights on the ECS cluster.
- CloudWatch alarms: ECS running-task-count < desired, CPU/memory > 80%, ALB 5xx rate above a
  threshold — wired to an SNS topic (email subscription is enough for now).

## Done criteria

- Backend logs show Redis connections succeeding; logout actually invalidates the refresh token
  (proves Redis is wired, not just reachable). **Met** — see live verification above.
- Alarms visible and in `OK` state in the CloudWatch console. **Met** — all 7 alarms `OK` as of
  this write-up (email confirmation for the SNS subscription is still outstanding — see above).
