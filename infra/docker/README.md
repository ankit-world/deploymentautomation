# infra/docker

Dockerfiles and docker-compose.yml for local orchestration (session 05).

- `backend.Dockerfile` — multi-stage Python 3.12 build for the FastAPI app.
- `frontend.Dockerfile` — multi-stage Node 22 build for the Next.js app (`NEXT_PUBLIC_API_URL` is
  a build ARG, not a runtime env var — see the comment block at the top of the file).
- `docker-compose.yml` — frontend + backend + Redis. MongoDB is not containerized; it stays on
  Atlas. Build context for both services is the repo root (see the comment at the top of the
  file for why).

Run from the repo root:

```
docker compose -f infra/docker/docker-compose.yml up --build
```

See root `README.md` ("Local development (Docker)") and
`docs/sessions/05-dockerization-local-e2e.md` for the full walkthrough and verification notes.
