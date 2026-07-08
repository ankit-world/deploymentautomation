# Session 10 — Grafana on Fargate

## Goal

Add the third ECS service: self-hosted Grafana, provisioned as code, reading metrics from
CloudWatch, reachable through the ALB.

## Prerequisites

- Session 08 done (ECS cluster/ALB/ECR live). Session 09 is a *soft* dependency, not hard: basic
  ECS/ALB CloudWatch metrics (CPUUtilization, RequestCount, TargetResponseTime,
  HTTPCode_Target_5XX_Count) are emitted by AWS by default regardless of Container Insights, so
  dashboards built here work without session 09 — the Container-Insights-level panels and the
  ElastiCache panel will just show no data until session 09's resources exist. Safe to build this
  session concurrently with session 09 (e.g. in a separate git worktree) rather than waiting.

## Deliverables

- `infra/docker/grafana.Dockerfile` — base Grafana image + baked-in provisioning:
  `provisioning/datasources/cloudwatch.yml` (CloudWatch datasource, IAM role for read access to
  CloudWatch metrics) and `provisioning/dashboards/*.json` (app-level dashboard: request rate/
  latency/errors if the backend exports custom metrics; infra dashboard: ECS CPU/mem, ALB
  request count/latency/5xx, ElastiCache CPU/connections).
- `infra/aws-cli-scripts/10-grafana-ecs.sh` — ECR repo push, task def (IAM task role with
  `cloudwatch:GetMetricData`/`ListMetrics`/`DescribeAlarms`), ECS service, ALB target group +
  listener rule for `/grafana/*`.
- Basic auth or Grafana's built-in admin login changed from the default (this is reachable on the
  open ALB pre-session-12, so don't leave default credentials).

## Done criteria

- `http://<alb-dns-name>/grafana` loads Grafana, logged in with non-default credentials, showing
  live ECS/ALB/ElastiCache metrics on the provisioned dashboards.

**Status**: done.

Built and deployed the third ECS service — self-hosted Grafana, config-as-code, live behind the
same ALB as the frontend/backend, without touching either of those services.

### What was built

- `infra/docker/grafana.Dockerfile` — `grafana/grafana-oss:11.3.0` (pinned, not `:latest`) with
  `infra/docker/grafana/provisioning/` baked in at `/etc/grafana/provisioning`:
  - `datasources/cloudwatch.yml` — CloudWatch datasource (`uid: cloudwatch`), `authType: default`
    so it uses the container's IAM task role via the ECS credentials endpoint — no static AWS
    keys anywhere in the image or task def.
  - `dashboards/dashboards.yml` — file-provider config, `allowUiUpdates: false` (dashboard stays
    in sync with the committed JSON, not UI edits against ephemeral container state).
  - `dashboards/infra-dashboard.json` — one dashboard (`chatapp-infra`), three row groups:
    - **ECS**: CPUUtilization and MemoryUtilization, one series per service
      (`chatapp-backend`/`chatapp-frontend`/`chatapp-grafana`) — confirmed showing real live data
      (see Verification below).
    - **ALB**: RequestCount, TargetResponseTime, HTTPCode_Target_5XX_Count on `chatapp-alb` — real
      default AWS metrics, no Container Insights needed.
    - **ElastiCache** (CPUUtilization, CurrConnections, dimension `CacheClusterId=chatapp-redis-001`
      — a placeholder guess at session 09's eventual node id, may need a one-line dimension fix
      once session 09 lands if it names the node differently) and **Container Insights**
      (CpuUtilized/MemoryUtilized under the `ECS/ContainerInsights` namespace) — both intentionally
      show "No data" right now per the relaxed prerequisite; they're wired up and will start
      populating once session 09's Redis node and Container Insights are live, no dashboard
      changes needed.
  - The base `grafana/grafana-oss` image already runs as non-root (uid 472) and exposes 3000 — no
    need to redeclare either.
- `infra/aws-cli-scripts/10-grafana-ecs.sh` — one script covering build/push, IAM, task def,
  ALB target group/rule, and ECS service (session 08 split this across three scripts only because
  two services shared the setup; one new service didn't need that split). Idempotent
  (describe-before-create throughout), follows the `.env.aws` read/write convention.
  - **Windows/Git-Bash gotcha found and fixed**: `MSYS_NO_PATHCONV=1` (needed for the AWS CLI's
    leading-`/` args, e.g. `/grafana*`) also stops Git Bash from converting the repo-root path
    into a Windows path for `docker build`, which is a native Windows binary and can't parse a
    POSIX `/c/...` path — `docker build -t ... "$REPO_ROOT"` failed with "unable to prepare
    context: path ... not found". Fixed by `cd`-ing into the repo root and building with `.` as
    the context (relative paths need no conversion either way) instead of passing an absolute
    path as an argument.
  - **ECS resources**: IAM task role `chatapp-grafana-task-role` (new, Grafana-only — inline
    policy `chatapp-cloudwatch-read` granting exactly `cloudwatch:GetMetricData`,
    `cloudwatch:ListMetrics`, `cloudwatch:DescribeAlarms`, nothing else, not the backend's S3
    role). Reuses the shared `chatapp-ecs-execution-role` for ECR pull/logs (granted one more
    inline-policy statement, `chatapp-read-grafana-secret`, to read the new admin-password
    secret — same shape as the backend's 4 secrets). Log group `/ecs/chatapp-grafana`. Task
    definition family `chatapp-grafana` (revision 1), 256 CPU / 512MB, container port 3000.
  - **Security group**: no change needed — `chatapp-ecs-sg` already allowed port 3000 from the
    ALB SG (the frontend already uses 3000), confirmed via `describe-security-groups` before
    assuming so, per the brief.
  - **ALB**: new target group `chatapp-grafana-tg` (port 3000, health check
    `/grafana/api/health`, matcher 200), new listener rule at **priority 20** (backend's existing
    rule is priority 10) matching `path-pattern /grafana*` -> forward to the new target group.
    Did not touch the existing default action or the priority-10 rule.
  - **Subpath serving gotcha** (discovered locally before deploying, not in the original brief):
    the ALB forwards the full original path unmodified — a request to `/grafana/login` arrives at
    the container as `/grafana/login`, not `/login`. Grafana must be told to serve from that
    subpath (`GF_SERVER_ROOT_URL=http://<alb-dns>/grafana/` +
    `GF_SERVER_SERVE_FROM_SUB_PATH=true`, both plain task-def environment entries) or its internal
    routing and static-asset links don't match incoming request paths. Verified locally via
    `docker run` with the same two env vars before writing the deploy script: `/grafana/login` and
    `/grafana/api/health` both returned 200 with correctly `/grafana/`-relative asset links in the
    HTML.
- **Admin credentials**: `chatapp/grafana-admin-password`, a 32-char random alnum string generated
  by `openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32`, created in Secrets Manager by the
  script (never printed to stdout, never written to any file in this repo) and injected into the
  task definition as a `secrets` entry (`GF_SECURITY_ADMIN_PASSWORD`); `GF_SECURITY_ADMIN_USER` is
  a plain (non-secret) env value, left as `admin`. Retrieve the actual password with:
  ```
  aws secretsmanager get-secret-value --secret-id chatapp/grafana-admin-password \
    --profile default --region us-east-1 --query SecretString --output text
  ```
  (run the `README.md` `unset AWS_ACCESS_KEY_ID ...` line first, same as any other command on this
  machine).

### Verified live (against the real ALB, not assumed)

1. **Target health**: `aws elbv2 describe-target-health` on `chatapp-grafana-tg` — state
   `healthy` after the service reached steady state.
2. **ALB routing**: `curl http://<alb-dns>/grafana/login` -> `200`; `curl
   http://<alb-dns>/grafana/api/health` -> `200` (`{"database":"ok","version":"11.3.0",...}`).
3. **Admin auth**: `curl -u admin:admin http://<alb-dns>/grafana/api/org` -> `401` (default
   credentials correctly rejected); `curl -u admin:<real password from Secrets Manager>
   http://<alb-dns>/grafana/api/org` -> `200` (real password works).
4. **CloudWatch datasource connectivity**: `POST /grafana/api/datasources/1/health` (through the
   live ALB, authenticated with the real admin password) returned `"1. Successfully queried the
   CloudWatch metrics API." status: "ERROR"` — the `ERROR` status is from part 2 of that same
   check (`CloudWatch logs query failed: AccessDeniedException ... logs:DescribeLogGroups`),
   which is **expected and correct**: the task role was deliberately scoped to only
   `GetMetricData`/`ListMetrics`/`DescribeAlarms` per the brief ("nothing else"), and this
   dashboard has no Logs Insights panels, so the missing `logs:*` permission is inconsequential.
   Went further than a bare health-check and confirmed the *metrics* path actually returns real
   data: `POST /grafana/api/ds/query` for `AWS/ECS` `CPUUtilization`,
   `ClusterName=chatapp-cluster`/`ServiceName=chatapp-backend` returned `status: 200` with ~36
   real datapoints (~1.0-2.1% CPU) — i.e. the dashboard's ECS panels are provably live, not just
   "no error."
5. **Existing services unaffected**: `curl http://<alb-dns>/health` (backend) -> `200`; `curl
   http://<alb-dns>/login` (frontend) -> `200` — both unchanged from session 08.

### Resource IDs

- ECR image: `788070448326.dkr.ecr.us-east-1.amazonaws.com/chatapp-grafana:manual-1`
- Task role: `arn:aws:iam::788070448326:role/chatapp-grafana-task-role`
- Task definition: `arn:aws:ecs:us-east-1:788070448326:task-definition/chatapp-grafana:1`
- Log group: `/ecs/chatapp-grafana`
- Target group: `chatapp-grafana-tg`
  (`arn:aws:elasticloadbalancing:us-east-1:788070448326:targetgroup/chatapp-grafana-tg/c40b32667b3434ab`)
- Listener rule: priority 20 on the existing `chatapp-alb` listener, `path-pattern=/grafana*`
- ECS service: `chatapp-grafana` on cluster `chatapp-cluster`, desired count 1
- Secret: `chatapp/grafana-admin-password` (Secrets Manager, see retrieval command above)

### Not done / left for later sessions

- ElastiCache and Container-Insights dashboard panels will show "No data" until session 09 lands
  (expected, per the relaxed prerequisite). The `CacheClusterId` dimension value used
  (`chatapp-redis-001`) is a guess — verify/adjust against whatever session 09 actually names the
  node.
- HTTPS (session 12) — Grafana, like everything else, is served over plain HTTP on the ALB's
  `*.elb.amazonaws.com` hostname for now; treat the admin login as staging-only until then.
- No CI/CD for this image yet (session 11) — redeploying currently means re-running
  `10-grafana-ecs.sh` by hand, same as the manual `manual-1` process session 08 used for
  frontend/backend.
