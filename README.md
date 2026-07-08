# ChatGPT-style App

A multi-user, ChatGPT-like web app: Next.js/TypeScript/Tailwind frontend, FastAPI backend,
MongoDB Atlas storage, OpenAI-powered chat with image/PDF/Word/Excel attachments, deployed on
AWS ECS Fargate behind an ALB, with Redis (ElastiCache), CloudWatch, self-hosted Grafana, and
GitHub Actions CI/CD.

## Status

Early scaffolding. See `docs/ROADMAP.md` for what's built and what's next.

## Project structure

```
/frontend     Next.js 14, TypeScript, Tailwind CSS
/backend      FastAPI, Python 3.12
/infra        AWS CLI provisioning scripts + Dockerfiles/compose
/docs         Architecture reference and per-session build briefs
```

## Where to start

- `docs/ARCHITECTURE.md` — full system design.
- `docs/ROADMAP.md` — the session-by-session build plan and current progress.
- `docs/sessions/` — one brief per session; each is self-contained enough to hand to a fresh
  Claude Code session.

## Local development (Docker)

The full stack (frontend + backend + Redis) runs via Docker Compose. MongoDB is **not**
containerized — both `docker compose` and any non-Docker local run talk to the real MongoDB Atlas
cluster, so dev and prod hit identical data-access code (see `docs/ARCHITECTURE.md`).

1. Copy `.env.example` to `.env` at the repo root and fill in real values (`MONGODB_URI`,
   `MONGODB_DB_NAME`, `JWT_SECRET`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`). This root `.env` is read
   automatically by `docker compose` via `env_file:` in `infra/docker/docker-compose.yml` —
   `REDIS_URL` and `NEXT_PUBLIC_API_URL` are *not* sourced from it for Docker (compose sets those
   itself; see the comments in `docker-compose.yml`/`frontend.Dockerfile` for why).
2. From the **repo root**, run:
   ```
   docker compose -f infra/docker/docker-compose.yml up --build
   ```
   (The compose file's build context is the repo root regardless of where you invoke it from, so
   `cd infra/docker && docker compose up --build` also works — both are supported, pick whichever
   is more convenient. This README documents the `-f` form since it doesn't require changing
   directories.)
3. Frontend: http://localhost:3000. Backend: http://localhost:8000 (`/health` for a liveness
   check). Redis is internal-only (no host port published) — service name `redis` inside the
   Docker network.
4. Uploaded files persist in a named volume (`chatapp_backend_uploads`) across
   `docker compose restart`/`down` (without `-v`). Tear down with
   `docker compose -f infra/docker/docker-compose.yml down` to keep that volume, or add `-v` to
   also wipe it (fine for local dev — the real source of truth, MongoDB Atlas, is untouched
   either way; only the local-disk file *bytes* are dropped).

See `docs/sessions/05-dockerization-local-e2e.md` for the full build/verification writeup,
including the `NEXT_PUBLIC_API_URL` build-time-vs-runtime gotcha and other judgment calls.

### Running without Docker

Run the frontend and backend directly (see sessions 01-04's briefs for specifics) — each needs
its own `.env`/`.env.local` (`backend/.env`, `frontend/.env.local`), separate from the root `.env`
Docker Compose uses.

## Secrets

Copy `.env.example` to `.env` (repo root, for Docker Compose) and fill in real values. Never
commit `.env`.

## CI/CD (session 11)

- `.github/workflows/ci.yml` — runs on every pull request: backend tests (`pytest`) and frontend
  lint + build (`npm run lint`, `npm run build`). No AWS access at all.
- `.github/workflows/deploy.yml` — runs on every push to `main`: builds and pushes all three
  Docker images (backend, frontend, grafana) to ECR tagged with the commit SHA, registers a new
  ECS task-definition revision for each service with the new image, force-deploys it, and waits
  for all three services to stabilize. Auth is via GitHub's OIDC provider assuming
  `chatapp-github-deploy` — no long-lived AWS keys stored in GitHub.

### Rollback

Every deploy registers a new task-definition revision under the same family; old revisions aren't
deleted, so rolling back is just pointing the service at a previous revision and forcing a fresh
deployment — no rebuild needed. Do this from a machine with the `default` AWS CLI profile
configured for this account (see `infra/aws-cli-scripts/README.md` for the local gotchas —
`unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` first).

1. Find the revision you want to roll back to:
   ```
   aws ecs list-task-definitions --family-prefix chatapp-backend --sort DESC --profile default --region us-east-1
   ```
   (swap `chatapp-backend` for `chatapp-frontend` or `chatapp-grafana` for the other two services —
   family name and service name are identical for all three).
2. Point the service at that revision and force a fresh deployment:
   ```
   aws ecs update-service --cluster chatapp-cluster --service chatapp-backend \
     --task-definition chatapp-backend:<previous-revision> --force-new-deployment \
     --profile default --region us-east-1
   ```
3. Wait for it to stabilize:
   ```
   aws ecs wait services-stable --cluster chatapp-cluster --services chatapp-backend \
     --profile default --region us-east-1
   ```
4. Confirm: `aws ecs describe-services --cluster chatapp-cluster --services chatapp-backend --query 'services[0].taskDefinition' --profile default --region us-east-1`, and re-check the app
   (`/health`, `/login`, `/grafana/api/health` on the ALB DNS name) behaves as expected.

This works for any of the three services (`chatapp-backend`, `chatapp-frontend`,
`chatapp-grafana`) — just substitute the service/family name. Rolling back does **not** revert
the ECR image tag or the Git history, only which task-definition revision (and therefore which
image) each service is currently running — the next push to `main` will redeploy the latest
commit again, so a rollback is a temporary mitigation, not a permanent fix.
