# Session 05 — Dockerization & Local End-to-End

## Goal

Containerize both apps and prove the full stack works together locally via docker-compose,
before touching any AWS infrastructure.

## Prerequisites

- Sessions 01-04 done (both frontend and backend feature-complete for MVP scope).

## Read first

- `docs/ARCHITECTURE.md` — Local development section, and the Backend/Frontend sections for the
  concrete env vars each app reads (`backend/app/core/config.py`'s `Settings` class is the
  authoritative list; `frontend/src/lib/api.ts`'s `NEXT_PUBLIC_API_URL` is the frontend's only one).
- Docker is installed and running on this machine (`docker --version`, `docker compose version`
  both work) — you can actually run and verify `docker compose up`, not just write the files.

## Critical gotcha: `NEXT_PUBLIC_API_URL` is a browser-side, build-time value

The frontend calls the backend directly from client components in the browser (no Next.js server
proxy) — see `frontend/src/lib/api.ts`. Next.js inlines `NEXT_PUBLIC_*` vars into the JS bundle at
**build time**; setting it in `docker-compose.yml`'s `environment:` section at container *runtime*
has no effect on an already-built frontend image. It must be passed as a Docker build arg to
`frontend.Dockerfile` and set to the **host-published** backend port
(`http://localhost:8000` — since the browser runs on the host machine, not inside the Docker
network) — never the Docker-internal service name (e.g. `http://backend:8000` would be wrong
here, that only works for container-to-container calls). Backend's `FRONTEND_ORIGIN` (CORS) should
correspondingly be `http://localhost:3000` (the host-published frontend port), matching how the
browser actually sees it.

Redis is the opposite case: `REDIS_URL` is read server-side by the backend container, so it
*should* use the Docker-internal service name (e.g. `redis://redis:6379/0`).

## Other things to get right

- File uploads use local-disk storage (`backend/app/services/storage.py`'s `LocalDiskStorage`,
  `UPLOAD_DIR` setting) — give the backend service a named volume for its upload directory so
  files survive container restarts/recreates.
- Secrets (`MONGODB_URI`, `JWT_SECRET`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`) already exist with
  real values in `backend/.env` (gitignored) — reuse those values for compose rather than asking
  the user again; source them via a root-level `.env` that `docker compose` reads automatically
  (root `.env.example` already has placeholders for most of these — extend it, don't duplicate).
  Never bake secrets into an image layer; inject via `environment:`/`env_file:` at container
  runtime only, same principle production will use with Secrets Manager (session 08).
- `frontend/next.config.ts` currently has no special `output` mode — consider adding
  `output: 'standalone'` so the runtime stage of the multi-stage build doesn't need the full
  `node_modules` tree (smaller image, faster builds). Your call if the added complexity is worth
  it for this session; document the decision either way.

## Deliverables

- `infra/docker/backend.Dockerfile` — multi-stage Python build (deps layer, then app).
- `infra/docker/frontend.Dockerfile` — multi-stage Node build (`next build` with the build-arg
  handling described above, then a slim runtime image, e.g. `node:*-slim` running `next start`).
- `infra/docker/docker-compose.yml` — frontend, backend, Redis; MongoDB stays Atlas (no local
  Mongo container — see architecture doc for why); env vars sourced from a root `.env`; named
  volume for backend uploads.
- Update root `README.md` with `docker compose up` instructions.

## Done criteria

- `docker compose up` brings up the full stack; signup/login, chat streaming, and file
  upload/preview/download all work end-to-end through the containerized services (verify by
  actually driving the app, e.g. via the same headless-Chromium approach prior sessions used),
  hitting the real MongoDB Atlas cluster and the Euri/Euron LLM gateway.
