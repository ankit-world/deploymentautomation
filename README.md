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
