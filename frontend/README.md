# frontend

Next.js 16 (App Router), TypeScript, Tailwind CSS. Session 03 scope — see
`docs/sessions/03-frontend-core.md`: auth pages (login/signup), a route gate, a sidebar of
conversations, and a chat pane that posts messages and renders the assistant's reply once it's
fully streamed (no token-by-token typing effect yet — that's session 04).

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
  body with credentials the way this needs).
- `src/contexts/AuthContext.tsx`, `ConversationsContext.tsx` — client-side auth/conversation-list
  state, shared between the sidebar and the chat pages.
- `src/app/login`, `src/app/signup` — public auth pages.
- `src/app/(protected)/` — everything else (route group, doesn't affect the URL): layout renders
  the sidebar and gates on `useAuth()`; `page.tsx` is the empty state at `/`; `c/[id]/page.tsx` is
  the actual chat thread.
- `src/components/Sidebar.tsx`, `MessageBubble.tsx` — UI pieces.

## API surface wired up (session 03)

- `POST /auth/signup`, `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout`,
  `GET /auth/me`
- `POST /conversations`, `GET /conversations`
- `GET /conversations/{id}/messages`, `POST /conversations/{id}/messages` (SSE, buffered and
  rendered once `event: done` arrives)

Conversation rename/delete and file upload/download exist on the backend but aren't wired into the
UI yet — that's session 04.
