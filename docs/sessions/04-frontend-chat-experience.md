# Session 04 — Frontend Chat Experience

**Status**: done. Verified live end-to-end (2026-07-08) against the real backend + Atlas +
Euri/Euron gateway, driving the actual UI with headless Chromium (Playwright), not just API calls:
- **Streaming**: sent "Count from 1 to 20…" and polled the assistant bubble's rendered text length
  every ~150ms while the request was in flight. Samples stayed flat at 22 chars ("Assistant is
  thinking…") for ~2.4s, then grew across multiple distinct samples (4 → 36 → 80 → 100 → 112 → 142
  → 169 → 192 → 208) before settling — proof the reply renders token-by-token via `onToken`, not
  as a single jump from 0 to full length on `onDone`.
- **Files**: generated fresh PNG/PDF/DOCX/XLSX fixtures (Pillow/reportlab/python-docx/openpyxl),
  each embedding a distinct "secret codeword". Uploaded each through the real composer's attach
  button, asked "What is the secret codeword in the file I just attached?", and confirmed the
  assistant's reply contained the correct codeword for all four files (proves the attachment
  reached the LLM through the real upload -> fileIds -> stream pipeline, not just that the UI
  displays a filename). Confirmed the image rendered as an `<img>` thumbnail and the other three
  rendered as icon/download cards. Downloaded every attachment back out via the per-attachment
  Download button and diffed sha256 against the original upload — byte-identical for all four.
- **Markdown**: asked for a bulleted list + fenced Python code block; the assistant bubble's HTML
  contained real `<ul><li>` and `<pre><code class="hljs language-python">` (with hljs syntax-
  highlighting spans), and no literal `**`/`` ``` `` characters leaked into the rendered text.
- `npm run build` and `npm run lint` both pass clean.
- Cleanup: deleted both throwaway test users (and their conversations/messages/file metadata) from
  Atlas via a one-off script against `app.core.db`, removed the local `backend/uploads/<conv_id>`
  directory created during upload testing, and confirmed no process remained listening on
  `:3000`/`:8000` afterward.

Judgment calls made this session (see `docs/ARCHITECTURE.md`'s Frontend section for the durable
version of these notes):
- **Download/preview via blob-fetch, not a bare `<a href>`/`<img src>`.** The backend's download
  route sets `Content-Disposition: attachment` on every response, including image kinds — that
  header's effect on an `<img>` subresource load (vs. a top-level navigation) is inconsistent
  across browsers, so `frontend/src/lib/files.ts` always fetches the bytes as a `Blob` (with the
  same cookie-based auth + 401-refresh-retry as the rest of the API client) and builds a throwaway
  object URL, for both inline image thumbnails and the explicit Download button. Slightly more
  code than a plain anchor tag, but removes the ambiguity entirely and works identically for every
  file kind.
- **Upload via `XMLHttpRequest`, not `fetch`.** `fetch` has no upload-progress event; `xhr.upload.
  onprogress` is the only way to drive a real per-file progress percentage for a multi-MB PDF/xlsx
  upload. Wrapped in a Promise in `uploadFile()` so callers still just `await` it.
- **Multiple attachments per message are supported** (the composer queues a list of pending
  uploads, each independently retryable/removable), even though the brief's examples were
  single-file — `MessageCreate.file_ids` is already a list, so this cost nothing extra.
- **Markdown/syntax highlighting**: `react-markdown` + `remark-gfm` (GFM tables/strikethrough/task
  lists) + `rehype-highlight` (highlight.js under the hood) + `@tailwindcss/typography`'s `prose`
  classes for spacing/typography. Chosen over `react-syntax-highlighter` for a smaller dependency
  footprint — `rehype-highlight` runs highlighting as a rehype plugin during the markdown AST
  transform rather than pulling in a second React component tree per code block. Tailwind v4 has
  no `tailwind.config.js` by default (CSS-first config) — the typography plugin is registered via
  `@plugin "@tailwindcss/typography";` in `globals.css` instead of a config file's `plugins` array;
  see the comment there if this looks unfamiliar (`frontend/AGENTS.md` flagged this Next.js
  16 / Tailwind v4 divergence from training-data conventions up front).
- **A sent message still requires non-empty text** (`MessageCreate.content` has `min_length=1` on
  the backend) — attachments augment a message, they can't be sent alone with empty text. The
  composer's Send button stays disabled while any attachment is still uploading, to avoid sending
  a message whose `fileIds` don't yet include a file the user thinks is attached.

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
