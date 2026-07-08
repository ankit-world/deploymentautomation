"""OpenAI-compatible chat completion client.

`settings.openai_base_url` points at a third-party OpenAI-*compatible* gateway (Euri/Euron,
`https://api.euron.one/api/v1/euri`), not api.openai.com. The official `openai` SDK supports
this natively via `base_url=`. Verified against the live gateway while building this module
(2026-07-07):

- `GET /models` returns a real-looking catalog of OpenAI/Anthropic/Google/Meta/Groq model ids
  all proxied through this one gateway. Do not assume it's actually OpenAI's models running —
  it's a router in front of several providers. `gpt-4o-mini` is present, non-premium (cheap),
  and vision-capable; it's the default (`settings.openai_model`).
- `stream=True` yields standard OpenAI `ChatCompletionChunk` objects — the openai SDK's normal
  streaming interface works unmodified; `chunk.choices[0].delta.content` behaves exactly like
  real OpenAI. No divergence found.
- Vision (`image_url` content parts with a base64 data URI) is accepted by `gpt-4o-mini` and
  produces accurate answers about image content (verified by asking it to name the solid color
  of a generated test image). `settings.vision_supported` gates this path — flip it to False if
  `openai_model` is ever changed to a non-vision model, and image attachments will degrade to a
  text note instead of erroring (see `build_user_message` below).

This is an MVP context-stuffing design, not RAG: extracted PDF/Word/Excel text is truncated
(`settings.extracted_text_max_chars`) and injected directly into the prompt alongside the
user's question, rather than chunked/embedded/retrieved.
"""

import logging
from collections.abc import AsyncIterator, Callable

from openai import AsyncOpenAI

from app.core.config import settings

logger = logging.getLogger(__name__)

_client = AsyncOpenAI(
    api_key=settings.openai_api_key,
    base_url=settings.openai_base_url or None,
    timeout=settings.llm_request_timeout_seconds,
)

SYSTEM_PROMPT = (
    "You are a helpful, concise assistant in a ChatGPT-style chat app. When the user's message "
    "includes text extracted from an attached PDF, Word, or Excel file, treat it as authoritative "
    "context for answering their question and reference it directly."
)


def build_user_message(content: str, attachments: list[dict]) -> dict:
    """Builds one OpenAI-style chat message dict for the user's turn, folding in attachments.

    `attachments` is a list of dicts with keys: kind ("image"|"pdf"|"docx"|"xlsx"|"other"),
    filename, mimetype, extracted_text (for document kinds), data_b64 (for image kind, raw
    bytes base64-encoded by the caller).

    - Document attachments (pdf/docx/xlsx): extracted text is appended to the text content.
    - Image attachments: sent as vision `image_url` parts if `settings.vision_supported`;
      otherwise degraded to a text note rather than sent to the API (which would error on a
      non-vision model).
    """
    text_parts = [content] if content else []
    image_parts: list[dict] = []

    for att in attachments:
        kind = att.get("kind")
        filename = att.get("filename") or "attachment"

        if kind == "image":
            if settings.vision_supported and att.get("data_b64"):
                mimetype = att.get("mimetype") or "image/png"
                image_parts.append(
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{mimetype};base64,{att['data_b64']}"},
                    }
                )
            else:
                text_parts.append(
                    f"\n\n[Attached image '{filename}' was received, but the configured model "
                    "does not support image inputs, so its contents could not be read.]"
                )
        else:
            extracted = att.get("extracted_text")
            if extracted:
                text_parts.append(f"\n\n--- Attached file: {filename} ---\n{extracted}")
            else:
                text_parts.append(
                    f"\n\n[Attached file '{filename}' was received, but no text could be "
                    "extracted from it.]"
                )

    full_text = "".join(text_parts) if text_parts else "(no message content)"

    if not image_parts:
        return {"role": "user", "content": full_text}

    return {"role": "user", "content": [{"type": "text", "text": full_text}, *image_parts]}


async def stream_chat_completion(
    messages: list[dict],
    model: str | None = None,
    on_usage: Callable[[dict], None] | None = None,
) -> AsyncIterator[str]:
    """Yields incremental text deltas from the chat completion, token-by-token.

    `on_usage`: optional callback invoked with `{"prompt_tokens", "completion_tokens",
    "total_tokens"}` once, if/when a usage-carrying chunk arrives — used by
    app/routers/messages.py to record LLM token metrics (see app/core/metrics.py). Requesting
    `stream_options={"include_usage": True}` is confirmed to work against the Euri/Euron gateway
    (verified live 2026-07-08: real prompt/completion/total token counts returned on the final
    chunk, same shape as real OpenAI) — not assumed, since this gateway has diverged from vanilla
    OpenAI behavior before in other ways (see this module's docstring above).
    """
    stream = await _client.chat.completions.create(
        model=model or settings.openai_model,
        messages=messages,
        stream=True,
        stream_options={"include_usage": True},
    )
    async for chunk in stream:
        usage = getattr(chunk, "usage", None)
        if usage is not None and on_usage is not None:
            on_usage(
                {
                    "prompt_tokens": usage.prompt_tokens,
                    "completion_tokens": usage.completion_tokens,
                    "total_tokens": usage.total_tokens,
                }
            )
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta.content
        if delta:
            yield delta
