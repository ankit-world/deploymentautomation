# Session 04 — Frontend Chat Experience

## Goal

Upgrade the basic chat UI from session 03 into the full ChatGPT-like experience: streaming
replies, file attachments with inline previews and downloads, markdown rendering.

## Prerequisites

- Session 03 done (basic chat UI working).
- Session 02 done (backend streaming + file endpoints live).

## Read first

- `docs/ARCHITECTURE.md` — Frontend section.

## Deliverables

- Replace the non-streaming fetch with an SSE/stream reader rendering tokens as they arrive.
- File attach button in the composer; upload progress state.
- Inline attachment rendering in message bubbles: image thumbnail (click to enlarge), PDF/Word/
  Excel as an icon card with filename + size; a download button hitting `/files/{id}/download`.
- Markdown rendering with fenced code blocks (syntax highlighting) for assistant messages.
- Loading/error/retry states for both chat and file upload.

## Done criteria

- Sending a message shows the assistant's reply streaming in visibly, not appearing all at once.
- Attaching an image, PDF, Word, and Excel file each show a correct inline preview and can be
  downloaded back out unmodified.
