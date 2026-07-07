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

**Status**: done.

## What was built

- `infra/docker/backend.Dockerfile` — multi-stage Python 3.12 build: `builder` stage installs
  `requirements.txt` into a venv (`build-essential` present only in this stage, in case a
  dependency has no manylinux wheel for the target arch), `runtime` stage copies just the venv +
  `app/` code, runs as a non-root `app` user, plain `uvicorn app.main:app` on `:8000`.
- `infra/docker/frontend.Dockerfile` — multi-stage Node 22 build: `deps` (npm ci), `builder`
  (`next build` with `NEXT_PUBLIC_API_URL` passed as a build **ARG**, not a runtime env var — see
  the gotcha section above and the long comment at the top of the Dockerfile), `runtime` (slim
  `node:22-slim`, copies only `.next/standalone` + `.next/static` + `public`, runs as non-root,
  `node server.js` on `:3000`). `frontend/next.config.ts` got `output: "standalone"` added
  specifically to make this runtime stage possible without a full `node_modules` copy —
  **judgment call made**: worth the added complexity, one extra config line for a materially
  smaller/faster image.
- `infra/docker/docker-compose.yml` — `redis` (internal-only, `redis:7-alpine`, healthchecked),
  `backend` (published `:8000`, `env_file: ../../.env` for secrets, `environment:` for
  Docker-topology values `REDIS_URL=redis://redis:6379/0` and `FRONTEND_ORIGIN=http://localhost:3000`,
  named volume `chatapp_backend_uploads` mounted at `/data/uploads` with `UPLOAD_DIR` overridden to
  match), `frontend` (published `:3000`, build arg `NEXT_PUBLIC_API_URL=http://localhost:8000`).
  **Judgment call**: build `context:` for both services is the **repo root** (`../..` from
  `infra/docker/`), not each app's own subdirectory — avoids Docker Compose's somewhat confusing
  "dockerfile path resolves relative to context, not to the compose file" rule (which gets
  genuinely awkward when the Dockerfile lives in a third directory, `infra/docker/`, different from
  both the compose file's directory and the app's directory). A root `.dockerignore` (new file,
  mirrors `.gitignore`) keeps the "sending build context" step from churning through
  `frontend/node_modules`, `backend/.venv`, `.git`, etc.
- Root `.env.example` extended with `MONGODB_DB_NAME` (was missing) and comments explaining which
  vars Docker Compose reads from the root `.env` vs. sets itself. Root `.env` (gitignored, not
  committed) created with the real secret values already present in `backend/.env`.
- Root `README.md` — new "Local development (Docker)" section with the exact `docker compose`
  invocation and volume-persistence notes.

## Bug found and fixed during verification

Live-testing the file-upload flow through the real containers (not just `docker compose build`,
which can't catch this) surfaced a **`PermissionError`** on the backend: `LocalDiskStorage.save()`
failed with `[Errno 13] Permission denied: '/data/uploads/<conversation_id>'`. Root cause: the
backend container runs as a non-root `app` user, and Docker creates a brand-new named volume's
mount point owned by `root` unless the image already has that path pre-created (with the desired
ownership) at build time — Docker then seeds the fresh volume from the image's existing directory,
ownership included. Fixed by adding `mkdir -p /data/uploads && chown -R app:app /data/uploads` to
`backend.Dockerfile` (alongside the existing `/app/uploads` fallback for the non-volume-mounted
default path) *before* `USER app`. This is a real gotcha worth remembering for any future
non-root-container + named-volume combination (e.g. session 09's ElastiCache doesn't have this
issue since Redis isn't disk-backed here, but any future EFS/EBS-backed volume on ECS would).

## Live verification performed (2026-07-08)

All driven against the real `docker compose up --build` stack (not `next dev`/local `uvicorn`),
via headless Chromium (Playwright), hitting the real MongoDB Atlas cluster and the real Euri/Euron
LLM gateway from inside the backend container:

1. **`docker compose -f infra/docker/docker-compose.yml up --build`** — all three containers
   (`chatapp-redis`, `chatapp-backend`, `chatapp-frontend`) reached `healthy`/`Up`. Confirmed the
   `NEXT_PUBLIC_API_URL` build-arg was actually inlined into the client bundle (not left as a
   runtime `process.env` lookup that would silently no-op): `docker exec chatapp-frontend grep -rl
   'localhost:8000' /app/.next/static` found it baked into a static chunk.
2. **Full signup -> conversation -> real streamed LLM reply**: signed up a throwaway user
   (`docker-e2e-<timestamp>@example.com`) through the real `/signup` form, created a conversation,
   sent "What is the capital of France?", and sampled the streaming assistant bubble's text length
   over time — samples stayed flat at 22 chars ("Assistant is thinking…") then grew across
   distinct steps before settling on "The capital of France is Paris.", proving real token-by-token
   SSE streaming through the containerized backend, not a buffered response. This proves the
   backend container has outbound internet access to both MongoDB Atlas and the Euri/Euron gateway.
3. **File upload/download, byte-identical**: uploaded a small text file, computed its sha256
   locally, asked the assistant about its content (confirming the extracted text reached the LLM
   prompt), then clicked Download and captured the browser's real `download` event. sha256 of the
   downloaded bytes matched the original exactly (`d85eefb9...52eea`, 60 bytes) — proves the upload
   volume mount and `LocalDiskStorage` path work correctly inside the container (after the
   permission fix above).
4. **Volume persistence across restart**: ran `docker compose restart backend`, waited for it to
   report `healthy` again, then in a **fresh** browser context (no reused cookies) logged back in
   as the same test user, navigated straight to the earlier conversation URL, and re-downloaded the
   same attachment — sha256 matched again. Proves `chatapp_backend_uploads` is a real persistent
   named volume, not container-ephemeral storage.
5. **Redis actually in use (not `fakeredis`)**: sent a fresh chat message, then immediately ran
   `docker compose exec redis redis-cli KEYS '*'` — found `ratelimit:chat:<user_id>` with `GET` ->
   `1` and `TTL` -> `43` (counting down from the configured 60s window). Since `fakeredis` runs
   entirely in-process inside the backend container, this key being visible from a `redis-cli`
   session against the *separate* `redis` container is direct proof `REDIS_URL=redis://redis:6379/0`
   is what's actually wired up, not the in-memory dev fallback.
6. **Cleanup**: a one-off script (same pattern as session 04) connected to the real Atlas cluster
   via the backend's own `motor` client and deleted every user matching the `docker-e2e-*` email
   prefix used by this session's test runs (2 users — including one from an earlier failed run
   whose email wasn't otherwise recorded, caught by the regex match) along with their conversations
   (2), messages (10), and file metadata docs (1). Then `docker compose down -v` — **judgment
   call**: `-v` was used because the named volume only ever held this session's throwaway test
   file, and the real persistent store (Atlas) had already been cleaned separately via the script
   above; there was nothing in the volume worth keeping across sessions. Confirmed via `docker ps
   -a` and `netstat` that no `chatapp-*` containers or listeners on `:3000`/`:8000`/`:6379`
   remained afterward.
