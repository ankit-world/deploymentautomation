# Session 03 — Frontend Core

## Goal

Scaffold the Next.js app with auth pages and a basic (non-streaming) chat UI wired to the real
backend from session 01. Can be built in parallel with sessions 01/02 in a separate worktree
since it only needs the backend's documented API shape, not a running instance, until final
wiring.

## Prerequisites

- Session 00 done. Ideally session 01 done too (needs live auth endpoints to wire against).

## Read first

- `docs/ARCHITECTURE.md` — Frontend section.

## Correction: the backend has no plain-JSON chat reply

This brief originally assumed `POST /messages` returns a normal JSON reply. It doesn't — session
02 shipped it as SSE-only (`POST /conversations/{id}/messages` returns
`text/event-stream`, never a plain JSON body). There's no non-streaming variant to fall back to.
So even "basic" session 03 must consume the SSE stream — the scope reduction for this session is
in the UI polish, not the protocol: buffer the stream and render the assistant's message only
once `event: done` arrives, with no token-by-token typing effect. The typing-effect UI upgrade is
session 04's job (`docs/sessions/04-frontend-chat-experience.md`).

## Backend API surface to wire against (all under `NEXT_PUBLIC_API_URL`, credentials: 'include')

- `POST /auth/signup` `{email, password, name}`, `POST /auth/login` `{email, password}`,
  `POST /auth/refresh`, `POST /auth/logout`, `GET /auth/me` — all cookie-based (httpOnly
  `access_token`/`refresh_token`), no bearer tokens to manage client-side.
- `POST /conversations` `{title?}`, `GET /conversations`, `PATCH /conversations/{id}` `{title}`,
  `DELETE /conversations/{id}`.
- `POST /conversations/{id}/messages` `{content, file_ids?}` → SSE stream:
  `event: user_message` (persisted user message, fires immediately), repeated `event: token`
  (`{"content": "<delta>"}`), optional `event: error` (`{"detail": "..."}`), final `event: done`
  (persisted assistant message). `GET /conversations/{id}/messages` → `MessageOut[]`.
- File endpoints exist (`POST /conversations/{id}/files`, `GET .../files/{file_id}/download`) but
  wiring them into the UI is session 04's job — session 03 just needs `MessageCreate` to accept an
  optional `file_ids: string[]` it won't populate yet.

See `docs/ARCHITECTURE.md`'s Backend section and `backend/app/routers/*.py` for full request/
response shapes (Pydantic models in `backend/app/models/`) if anything here is ambiguous.

## Deliverables

- `frontend/` Next.js 14 App Router + TypeScript + Tailwind, created via `create-next-app`.
- Login/signup pages posting to the backend auth endpoints; JWT cookie handling (cookies are set
  by the backend response — the frontend just needs `credentials: 'include'` on every fetch).
- Middleware protecting all routes except `/login`, `/signup`.
- Sidebar listing the user's conversations (fetched from `/conversations`); "new conversation"
  action.
- Main chat pane: message list + composer input, posting to `/conversations/{id}/messages` and
  consuming the SSE stream (buffer-and-render-on-`done` is fine for this session; see above).
- `frontend/.env.example` documenting `NEXT_PUBLIC_API_URL` etc.

## Done criteria

- Can sign up, log in, create a conversation, send a message, and see the assistant's real reply
  (from the live backend + Euri/Euron gateway) rendered, end to end against the session-01/02
  backend running locally.
