# Session 04 — Frontend Chat Experience

## Goal

Upgrade the basic chat UI from session 03 into the full ChatGPT-like experience: streaming
replies, file attachments with inline previews and downloads, markdown rendering.

## Prerequisites

- Session 03 done (basic chat UI working).
- Session 02 done (backend streaming + file endpoints live).

## Read first

- `docs/ARCHITECTURE.md` — Frontend section (session 03 added real detail here: the two-layer
  auth-gate design, why SSE is hand-parsed instead of `EventSource`, cross-port cookie notes).
- `frontend/src/lib/messages.ts` — session 03 already built the SSE parser and wired an `onToken`
  handler; it's just unused for incremental rendering (`frontend/src/app/(protected)/c/[id]/
  page.tsx` currently only uses `onDone`, buffering the whole reply — see the comment there). Your
  job is mostly to *use* `onToken` to update state per-delta, not to rebuild SSE parsing.
- `frontend/src/components/MessageBubble.tsx` — currently renders `message.content` as plain text
  and `message.attachments` as a bare filename list. This is what needs the markdown/attachment
  upgrade.
- `backend/app/routers/files.py` — the upload/download contract: `POST
  /conversations/{id}/files` takes `multipart/form-data` with a `file` field, returns `FileOut`
  (`id, conversation_id, filename, mimetype, kind, size, extracted_text_preview, created_at`,
  `kind` is one of `image|pdf|docx|xlsx|other`). `GET
  /conversations/{id}/files/{file_id}/download` streams the raw bytes back with a
  `Content-Disposition: attachment` header (requires the auth cookie — fetch-as-blob-then-trigger-
  download is more robust than a bare `<a href>` if you're unsure about cross-origin cookie
  behavior, though Lax-cookie top-level GET navigation would likely also work here since
  `localhost:3000`/`:8000` are same-site; your call).
- `backend/app/models/message.py` — `MessageCreate.file_ids: list[str]` already exists; session 03
  never populates it. `frontend/src/lib/messages.ts`'s `streamMessage()` already accepts a
  `fileIds` parameter for this — currently always called with `[]`.

## Deliverables

- Wire `onToken` in the chat page into incremental UI state so the assistant's reply visibly
  streams in token-by-token, not appearing all at once on `onDone`.
- File attach button in the composer: a new `uploadFile()` wrapper in (a new) `frontend/src/lib/
  files.ts` hitting the multipart upload endpoint above, upload progress/pending state, and
  passing the resulting file id(s) as `fileIds` into `streamMessage()` so they attach to the next
  sent message.
- Inline attachment rendering in `MessageBubble.tsx`: image thumbnail (click to enlarge — a
  simple modal/lightbox is enough, no need for a library), PDF/Word/Excel as an icon card with
  filename + size; a download button per attachment hitting the download endpoint above.
- Markdown rendering with fenced code blocks (syntax highlighting) for assistant messages — pick
  reasonable, actively-maintained libraries (e.g. `react-markdown` + `remark-gfm` +
  a highlighter); user messages can stay plain text (no need to markdown-render what the user
  typed).
- Loading/error/retry states for both chat sending and file upload.

## Done criteria

- Sending a message shows the assistant's reply streaming in visibly (tokens appearing
  progressively), not appearing all at once.
- Attaching an image, PDF, Word, and Excel file each show a correct inline preview and can be
  downloaded back out byte-for-byte unmodified, verified against the real backend (not mocked).
- Assistant replies containing markdown (a list, a fenced code block) render formatted, not as
  raw text with literal `**`/`` ``` `` characters.
