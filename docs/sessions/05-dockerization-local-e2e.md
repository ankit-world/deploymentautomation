# Session 05 — Dockerization & Local End-to-End

## Goal

Containerize both apps and prove the full stack works together locally via docker-compose,
before touching any AWS infrastructure.

## Prerequisites

- Sessions 01-04 done (both frontend and backend feature-complete for MVP scope).

## Read first

- `docs/ARCHITECTURE.md` — Local development section.

## Deliverables

- `infra/docker/backend.Dockerfile` — multi-stage Python build (deps layer, then app).
- `infra/docker/frontend.Dockerfile` — multi-stage Node build (`next build`, then a slim runtime
  image, e.g. `node:*-slim` running `next start`).
- `infra/docker/docker-compose.yml` — frontend, backend, Redis; MongoDB stays Atlas (no local
  Mongo container — see architecture doc for why); env vars sourced from a root `.env`.
- Update root `README.md` with `docker compose up` instructions.

## Done criteria

- `docker compose up` brings up the full stack; signup/login, chat streaming, and file
  upload/preview/download all work end-to-end through the containerized services, hitting the
  real MongoDB Atlas cluster and OpenAI API.
