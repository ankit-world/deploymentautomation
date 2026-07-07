# Session 02 — Backend LLM + Files

## Goal

Add the OpenAI-powered chat reply (streaming) and file attachment upload/parse/download to the
backend built in session 01.

## Prerequisites

- Session 01 done (auth + conversation/message CRUD working).
- An OpenAI API key, provided by the user as `OPENAI_API_KEY`.

## Read first

- `docs/ARCHITECTURE.md` — Backend section (LLM integration + file storage subsections).

## Deliverables

- `app/services/llm.py` — OpenAI client wrapper; SSE-streaming chat completion; vision input for
  images; text-injection for extracted PDF/Word/Excel content.
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
