# Session 02 — Backend LLM + Files

## Goal

Add the OpenAI-powered chat reply (streaming) and file attachment upload/parse/download to the
backend built in session 01.

## Prerequisites

- Session 01 done (auth + conversation/message CRUD working, verified live against Atlas).
- `backend/.env` already has real values for `OPENAI_API_KEY` and `OPENAI_BASE_URL` — no need to
  ask the user for these again.

## Important: this is not api.openai.com

`OPENAI_BASE_URL` points at `https://api.euron.one/api/v1/euri`, an OpenAI-*compatible* gateway
(Euri/Euron), not OpenAI directly. Use the official `openai` Python SDK but construct the client
with `base_url=settings.openai_base_url` (SDK supports this natively —
`OpenAI(api_key=..., base_url=...)`). Before building the full abstraction:

1. Hit the endpoint directly (e.g. `curl $OPENAI_BASE_URL/models` or a one-off SDK call) to find
   out which model names it actually serves — don't assume `gpt-4o` or any specific OpenAI model
   name exists on this gateway.
2. Confirm whether streaming (`stream=True`) returns standard OpenAI-style SSE chunks.
3. Confirm whether it accepts vision-style image inputs (`image_url` content parts) at all — if
   not, the image-attachment path needs a fallback (e.g. reject with a clear error, or describe
   the limitation to the user) rather than assuming vision works.

If any of these diverge from OpenAI's actual behavior, note the divergence in
`docs/ARCHITECTURE.md`'s LLM integration section so later sessions don't re-assume vanilla OpenAI.

## Read first

- `docs/ARCHITECTURE.md` — Backend section (LLM integration + file storage subsections).

## Deliverables

- `app/services/llm.py` — OpenAI-compatible client wrapper (custom `base_url`); SSE-streaming
  chat completion; vision input for images if the gateway supports it; text-injection for
  extracted PDF/Word/Excel content.
- `app/services/extract.py` — text extraction: pdfplumber (PDF), python-docx (Word),
  openpyxl/pandas (Excel).
- `app/services/storage.py` — storage abstraction with a local-disk implementation now and an S3
  implementation stubbed for session 08 (don't need real AWS access to write the interface).
- `app/routers/files.py` — upload (stores file, extracts text, returns metadata + preview),
  download (streams bytes in dev; presigned-URL redirect once S3 exists).
- Wire `messages.py`'s POST endpoint to actually call the LLM service and stream the reply.
- Redis-backed per-user rate limit on the chat endpoint (`REDIS_URL`, local Redis for dev).

## Done criteria

- Posting a text message streams back a real OpenAI response token-by-token.
- Uploading an image, PDF, Word doc, and Excel file each produce correct metadata + extracted
  text, and asking a question referencing the file's content gets a relevant answer.
- Download endpoint returns the original file bytes unmodified.
