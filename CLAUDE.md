# CLAUDE.md

Multi-user ChatGPT-style app: **Next.js** frontend + **FastAPI** backend + **MongoDB Atlas**,
LLM chat with image/PDF/Word/Excel attachments, deployed on **AWS ECS Fargate** behind an ALB with
ElastiCache, CloudWatch, self-hosted Grafana, and GitHub Actions CI/CD (OIDC, no stored keys).

**Live:** http://chatapp-alb-811403579.us-east-1.elb.amazonaws.com (HTTP only — HTTPS is deferred).

## Read these before non-trivial work

- `docs/PLAYBOOK.md` — how the whole system fits together + why, the 12-session build recipe, and
  the **hard-won gotchas list** (section 11). Read it before changing architecture or rebuilding.
- `docs/ARCHITECTURE.md` — full current system design; the source of truth for specifics. Update it
  when a change alters a decision recorded there.
- `docs/ROADMAP.md` — session checklist + post-roadmap follow-ups.
- `infra/aws-cli-scripts/README.md` — **required reading before any AWS CLI command** (see below).

## Repo layout

```
/frontend   Next.js App Router, TypeScript, Tailwind (route gate is src/proxy.ts, not middleware.ts)
/backend    FastAPI, Python 3.12 (app/core, app/models, app/routers, app/services; tests/, scripts/)
/infra      aws-cli-scripts/ (numbered *.sh + setup-all.ps1 + 99-cleanup.sh), docker/
/docs       PLAYBOOK.md, ARCHITECTURE.md, ROADMAP.md, sessions/
.github/workflows  ci.yml (PR: test+lint), deploy.yml (push→main: test-gated build/push/deploy)
```

## Commands

```bash
# Backend (from backend/)
./.venv/Scripts/python -m pytest -q            # 52 tests, mongomock-motor + fakeredis, no real infra
./.venv/Scripts/python -m scripts.ensure_indexes   # create Mongo indexes (idempotent, run manually)

# Frontend (from frontend/)
npm run lint && npm run build

# Full stack locally (from repo root) — MongoDB is real Atlas, not containerized
docker compose -f infra/docker/docker-compose.yml up --build
# Frontend :3000 · Backend :8000/health · Redis internal-only

# Deploy = push to main (deploy.yml gates on tests, then build→push ECR→redeploy ECS→health-check)
```

## Conventions & guardrails

- **Before ANY `aws` command on this machine**, run `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN` in the *same* command, then confirm `aws sts get-caller-identity` shows account
  `788070448326` / user `ankitexp`. Stray env-var credentials silently outrank `--profile` here and
  have created resources in the wrong account before. Shell state does not persist between tool
  calls — the `unset` must be in the same invocation as the AWS call.
- On Git Bash, `export MSYS_NO_PATHCONV=1` before any AWS command with a leading-`/` argument
  (log group names, URL paths, IAM paths) — MSYS mangles them into Windows paths otherwise.
- Build external clients **lazily**, never at module import time (an eager `AsyncOpenAI(api_key="")`
  crashes pytest collection in any keyless environment — see PLAYBOOK gotchas).
- `NEXT_PUBLIC_*` vars are build-time (Docker `ARG`), not runtime — they're inlined into the client
  bundle at `next build`.
- Redis is for rate-limit counters + refresh-token blacklist only — **not** a response/LLM cache.
- Secrets live only in AWS Secrets Manager (injected into ECS containers at start via the execution
  role) and local `.env`/`.env.aws` (gitignored). Never commit them, never bake into an image.
- Verify live, not just via unit tests — the exception-handler/middleware bug and the LLM eager-init
  crash both passed mocked tests and only surfaced against real infrastructure.
- End commit messages with the `Co-Authored-By: Claude <...>` trailer. Only commit/push when asked.

## Deploy & rollback

`deploy.yml` runs on push to `main`, gated on `backend-tests`/`frontend-checks`. Rollback = point a
service at a previous task-def revision (old revisions are never deleted):
`aws ecs update-service --cluster chatapp-cluster --service chatapp-backend --task-definition
chatapp-backend:<rev> --force-new-deployment`. Full steps in root `README.md`. Tear everything down
to stop billing with `infra/aws-cli-scripts/99-cleanup.sh` (`--dry-run` first).
