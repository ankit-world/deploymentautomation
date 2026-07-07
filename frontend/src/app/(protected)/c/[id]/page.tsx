"use client";

import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { useParams } from "next/navigation";
import { useConversations } from "@/contexts/ConversationsContext";
import { listMessages, streamMessage } from "@/lib/messages";
import type { Message } from "@/lib/api";
import { ApiError } from "@/lib/api";
import MessageBubble from "@/components/MessageBubble";

export default function ConversationPage() {
  const params = useParams<{ id: string }>();
  const conversationId = params.id;
  const { refresh: refreshConversations } = useConversations();

  const [messages, setMessages] = useState<Message[]>([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let cancelled = false;
    // Standard fetch-on-mount(/on-param-change) pattern: reset loading/error state, then set the
    // real result inside the promise callbacks below. eslint-plugin-react-hooks 7's
    // set-state-in-effect rule flags any setState reachable from an effect, including this
    // well-established idiom, so it's disabled here rather than restructured away.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoadingHistory(true);
    setError(null);
    listMessages(conversationId)
      .then((data) => {
        if (!cancelled) setMessages(data);
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof ApiError ? err.message : "Failed to load messages.");
        }
      })
      .finally(() => {
        if (!cancelled) setLoadingHistory(false);
      });
    return () => {
      cancelled = true;
    };
  }, [conversationId]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, sending]);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const trimmed = input.trim();
    if (!trimmed || sending) return;

    setInput("");
    setSending(true);
    setError(null);

    try {
      // Session 03 scope: buffer the whole SSE stream and render the assistant's message only
      // once `event: done` arrives (no token-by-token typing effect yet - that's session 04).
      // `sending` alone drives the "assistant is thinking" indicator below.
      await streamMessage(conversationId, trimmed, [], {
        onUserMessage: (message) => setMessages((prev) => [...prev, message]),
        onDone: (message) => {
          setMessages((prev) => [...prev, message]);
          // Bumps the sidebar's ordering (backend updates the conversation's `updated_at` on
          // every message).
          refreshConversations();
        },
        onError: (detail) => setError(detail),
      });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to send message.");
    } finally {
      setSending(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      <div className="flex-1 space-y-4 overflow-y-auto px-4 py-6">
        {loadingHistory && <p className="text-sm text-neutral-500">Loading messages…</p>}
        {!loadingHistory && messages.length === 0 && (
          <p className="text-sm text-neutral-500">Say something to start the conversation.</p>
        )}
        {messages.map((message) => (
          <MessageBubble key={message.id} message={message} />
        ))}
        {sending && (
          <div className="flex justify-start">
            <div className="rounded-2xl bg-neutral-100 px-4 py-2 text-sm text-neutral-500 dark:bg-neutral-800">
              Assistant is thinking…
            </div>
          </div>
        )}
        <div ref={bottomRef} />
      </div>

      {error && (
        <p className="border-t border-red-200 bg-red-50 px-4 py-2 text-sm text-red-600 dark:border-red-900 dark:bg-red-950 dark:text-red-400">
          {error}
        </p>
      )}

      <form
        onSubmit={handleSubmit}
        className="flex gap-2 border-t border-neutral-200 p-4 dark:border-neutral-800"
      >
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Send a message…"
          disabled={sending}
          className="flex-1 rounded-md border border-neutral-300 px-3 py-2 text-sm outline-none focus:border-neutral-500 disabled:opacity-60 dark:border-neutral-700 dark:bg-neutral-900"
        />
        <button
          type="submit"
          disabled={sending || !input.trim()}
          className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-60 dark:bg-white dark:text-neutral-900"
        >
          {sending ? "Sending…" : "Send"}
        </button>
      </form>
    </div>
  );
}
