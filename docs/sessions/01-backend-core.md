# Session 01 — Backend Core

**Status**: done. Auth + conversation/message CRUD implemented and passing 10 pytest cases
against an in-memory Mongo mock; app boots and serves `/health`/`/docs`. Still needs a live
smoke test against a real MongoDB Atlas cluster once `backend/.env` has a real `MONGODB_URI` —
do that before starting session 02.

## Goal

Stand up the FastAPI backend skeleton with working auth and conversation/message persistence
against MongoDB Atlas. No LLM calls and no file handling yet — that's session 02.

## Prerequisites

- Session 00 done (repo skeleton exists).
- A MongoDB Atlas cluster and connection string, provided by the user as `MONGODB_URI`.

## Read first

- `docs/ARCHITECTURE.md` — Backend section for the full design (routers, auth model, secrets).

## Deliverables

- `backend/` FastAPI project: `pyproject.toml` or `requirements.txt`, `app/main.py`,
  `app/core/config.py` (pydantic-settings reading env vars: `MONGODB_URI`, `JWT_SECRET`,
  `REDIS_URL`), `app/core/db.py` (Motor client + DB dependency).
- `app/models/` — Pydantic models for `User`, `Conversation`, `Message`.
- `app/routers/auth.py` — signup, login, refresh, logout. Bcrypt password hashing, JWT
  access+refresh tokens in httpOnly cookies.
- `app/routers/conversations.py` — create/list/rename/delete, scoped to the authenticated user
  (JWT dependency).
- `app/routers/messages.py` — create a message on a conversation (text only for now; the LLM
  reply and streaming come in session 02 — stub the assistant reply or leave the endpoint
  returning a placeholder so the shape is right).
- `tests/` — pytest suite covering signup/login/refresh/logout and conversation CRUD, using
  `mongomock`/`motor` test doubles or a scratch Atlas test database.
- `backend/.env.example` (or extend the root one) documenting required env vars.

## Done criteria

- `uvicorn app.main:app` runs locally against a real Atlas connection string.
- Signup → login → create conversation → post message → list conversations round-trips
  correctly, verified via `pytest` and a manual `curl`/httpx smoke test.
- No secrets committed; `MONGODB_URI`/`JWT_SECRET` only ever read from env.
