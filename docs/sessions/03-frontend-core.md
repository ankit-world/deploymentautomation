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

## Deliverables

- `frontend/` Next.js 14 App Router + TypeScript + Tailwind, created via `create-next-app`.
- Login/signup pages posting to the backend auth endpoints; JWT cookie handling.
- Middleware protecting all routes except `/login`, `/signup`.
- Sidebar listing the user's conversations (fetched from `/conversations`); "new conversation"
  action.
- Main chat pane: message list + composer input, posting to `/messages` and rendering the
  (non-streamed) reply.
- `frontend/.env.example` documenting `NEXT_PUBLIC_API_URL` etc.

## Done criteria

- Can sign up, log in, create a conversation, send a message, and see the assistant's reply
  rendered, end to end against the session-01/02 backend running locally.
