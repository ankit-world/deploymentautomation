# frontend

Next.js 16 (App Router), TypeScript, Tailwind CSS. Session 03 (`docs/sessions/03-frontend-core.md`)
built auth pages (login/signup), a route gate, a sidebar of conversations, and a basic chat pane.
Session 04 (`docs/sessions/04-frontend-chat-experience.md`) upgraded the chat pane to the full
experience: assistant replies stream in token-by-token, file attachments (image/PDF/Word/Excel)
upload with progress and render inline previews with download, and assistant messages render as
markdown with syntax-highlighted code blocks.

Talks directly to the FastAPI backend (`../backend`) over `fetch` with `credentials: 'include'` —
auth is entirely the backend's httpOnly JWT cookies, there's no client-side token management.

## Setup

```
cd frontend
npm install
cp .env.example .env.local     # defaults already point at http://localhost:8000
```

## Run

```
npm run dev
```

Visit `http://localhost:3000`. You'll be redirected to `/login` until you sign up / log in.

The backend must be running separately (`cd ../backend && .venv/Scripts/python -m uvicorn
app.main:app --reload`) and its `FRONTEND_ORIGIN` (in `backend/.env`) must match whatever origin
this dev server is actually on — defaults to `http://localhost:3000` on both sides, so running
both on their default ports needs no changes.

## Build

```
npm run build
npm start
```

## Lint

```
npm run lint
```

## App structure

- `src/proxy.ts` — route gate (Next.js 16 renamed `middleware.ts` to `proxy.ts`; see the comment
  at the top of that file for why). Redirects to `/login` when the `access_token` cookie is
  absent; the authoritative check (does the token actually still validate) happens client-side
  via `GET /auth/me` in `src/contexts/AuthContext.tsx`, since proxy can't verify a JWT signature
  without duplicating the backend's `JWT_SECRET` into frontend code. See the extended comment in
  `src/proxy.ts` and `docs/ARCHITECTURE.md`'s Frontend section for the full reasoning.
- `src/lib/api.ts` — shared `fetch` wrapper: base URL, `credentials: 'include'`, and transparent
  `POST /auth/refresh` + retry on a 401.
- `src/lib/auth.ts`, `conversations.ts`, `messages.ts` — typed wrappers for each backend router.
  `messages.ts`'s `streamMessage()` hand-parses the backend's SSE framing (`event: ...` /
  `data: ...` blocks) via `fetch` + `ReadableStream`, not `EventSource` (which can't POST a JSON
  body with credentials the way this needs); `c/[id]/page.tsx` consumes its `onToken` handler to
  render the assistant's reply incrementally.
- `src/lib/files.ts` (session 04) — `uploadFile()` (multipart upload via `XMLHttpRequest`, for
  upload-progress events `fetch` doesn't have), `fetchFileBlob()`/`downloadFile()` (blob-fetch,
  not a bare `<a href>`/`<img src>` — see `docs/ARCHITECTURE.md`'s Frontend section for why).
- `src/contexts/AuthContext.tsx`, `ConversationsContext.tsx` — client-side auth/conversation-list
  state, shared between the sidebar and the chat pages.
- `src/app/login`, `src/app/signup` — public auth pages.
- `src/app/(protected)/` — everything else (route group, doesn't affect the URL): layout renders
  the sidebar and gates on `useAuth()`; `page.tsx` is the empty state at `/`; `c/[id]/page.tsx` is
  the actual chat thread (streaming, attachments, retry states).
- `src/components/Sidebar.tsx`, `MessageBubble.tsx` (markdown rendering for assistant messages),
  `Attachment.tsx` (session 04 — image thumbnail/lightbox, PDF/Word/Excel icon card, download).

## API surface wired up

- `POST /auth/signup`, `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout`,
  `GET /auth/me`
- `POST /conversations`, `GET /conversations`
- `GET /conversations/{id}/messages`, `POST /conversations/{id}/messages` (SSE, rendered
  token-by-token as it streams)
- `POST /conversations/{id}/files` (upload), `GET /conversations/{id}/files/{file_id}/download`

Conversation rename/delete exist on the backend but aren't wired into the UI yet.
