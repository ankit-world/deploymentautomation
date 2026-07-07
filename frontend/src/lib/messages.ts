import { API_BASE_URL, ApiError, apiFetch, tryRefresh, type Message } from "./api";

export async function listMessages(conversationId: string): Promise<Message[]> {
  return apiFetch<Message[]>(`/conversations/${conversationId}/messages`);
}

export interface StreamHandlers {
  /** Fires immediately with the persisted user message (has its real id before any tokens). */
  onUserMessage?: (message: Message) => void;
  /** Fires per `event: token`. Session 03 buffers the whole stream (see onDone) rather than
   * rendering these incrementally — that's session 04's typing-effect job — but the handler is
   * still wired up so callers can show "assistant is typing" activity if they want. */
  onToken?: (delta: string) => void;
  /** Fires on `event: error` (LLM call failed). `event: done` still follows with a fallback
   * assistant message, per the backend's contract (see backend/app/routers/messages.py). */
  onError?: (detail: string) => void;
  /** Fires on `event: done` with the persisted assistant message — this is what session 03
   * renders. */
  onDone?: (message: Message) => void;
}

/**
 * POSTs a new message and consumes the backend's SSE reply
 * (`event: user_message` -> repeated `event: token` -> optional `event: error` -> `event: done`).
 *
 * The backend never returns a plain JSON body for this endpoint (see
 * docs/sessions/03-frontend-core.md's "Correction" section) — `text/event-stream` is the only
 * response shape, so this reads the response body as a stream and parses the SSE framing by
 * hand (fetch + ReadableStream, not EventSource, since EventSource can't do POST with a JSON
 * body or send credentials the way we need here).
 */
export async function streamMessage(
  conversationId: string,
  content: string,
  fileIds: string[] = [],
  handlers: StreamHandlers = {},
  _isRetry = false,
): Promise<void> {
  const res = await fetch(`${API_BASE_URL}/conversations/${conversationId}/messages`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content, file_ids: fileIds }),
  });

  if (res.status === 401 && !_isRetry) {
    const refreshed = await tryRefresh();
    if (refreshed) {
      return streamMessage(conversationId, content, fileIds, handlers, true);
    }
    throw new ApiError(401, "Not authenticated");
  }

  if (!res.ok || !res.body) {
    let detail = res.statusText;
    try {
      const body = await res.json();
      detail = body.detail ?? detail;
    } catch {
      // non-JSON error body; keep statusText
    }
    throw new ApiError(res.status, detail);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    let separatorIndex: number;
    while ((separatorIndex = buffer.indexOf("\n\n")) !== -1) {
      const rawEvent = buffer.slice(0, separatorIndex);
      buffer = buffer.slice(separatorIndex + 2);
      dispatchSseBlock(rawEvent, handlers);
    }
  }

  // Flush a trailing block that wasn't terminated by a final blank line.
  if (buffer.trim()) {
    dispatchSseBlock(buffer, handlers);
  }
}

function dispatchSseBlock(block: string, handlers: StreamHandlers): void {
  let eventName = "message";
  let dataLine = "";

  for (const line of block.split("\n")) {
    if (line.startsWith("event:")) {
      eventName = line.slice("event:".length).trim();
    } else if (line.startsWith("data:")) {
      dataLine += line.slice("data:".length).trim();
    }
  }

  if (!dataLine) return;

  let data: unknown;
  try {
    data = JSON.parse(dataLine);
  } catch {
    return;
  }

  switch (eventName) {
    case "user_message":
      handlers.onUserMessage?.(data as Message);
      break;
    case "token":
      handlers.onToken?.((data as { content: string }).content);
      break;
    case "error":
      handlers.onError?.((data as { detail: string }).detail);
      break;
    case "done":
      handlers.onDone?.(data as Message);
      break;
    default:
      break;
  }
}

export type { Message };
