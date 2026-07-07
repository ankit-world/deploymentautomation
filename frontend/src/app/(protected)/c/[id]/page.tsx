"use client";

import { useEffect, useRef, useState } from "react";
import type { ChangeEvent, FormEvent } from "react";
import { useParams } from "next/navigation";
import { useConversations } from "@/contexts/ConversationsContext";
import { listMessages, streamMessage } from "@/lib/messages";
import type { Message } from "@/lib/api";
import { ApiError } from "@/lib/api";
import { uploadFile } from "@/lib/files";
import type { FileOut } from "@/lib/files";
import MessageBubble from "@/components/MessageBubble";

interface PendingAttachment {
  localId: string;
  file: File;
  status: "uploading" | "done" | "error";
  progress: number;
  error?: string;
  fileOut?: FileOut;
}

let localIdCounter = 0;
function nextLocalId(): string {
  localIdCounter += 1;
  return `pending-${localIdCounter}`;
}

export default function ConversationPage() {
  const params = useParams<{ id: string }>();
  const conversationId = params.id;
  const { refresh: refreshConversations } = useConversations();

  const [messages, setMessages] = useState<Message[]>([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  // The assistant's reply as it streams in token-by-token (event: token). Rendered as its own
  // bubble alongside the persisted `messages` list, then discarded once event: done delivers the
  // real, persisted Message (which replaces it via the normal setMessages append).
  const [streamingMessage, setStreamingMessage] = useState<Message | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lastAttempt, setLastAttempt] = useState<{ content: string; fileIds: string[] } | null>(
    null,
  );
  const [attachments, setAttachments] = useState<PendingAttachment[]>([]);
  const bottomRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    let cancelled = false;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoadingHistory(true);
    setHistoryError(null);
    listMessages(conversationId)
      .then((data) => {
        if (!cancelled) setMessages(data);
      })
      .catch((err) => {
        if (!cancelled) {
          setHistoryError(err instanceof ApiError ? err.message : "Failed to load messages.");
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
  }, [messages, sending, streamingMessage]);

  async function runUpload(pending: PendingAttachment) {
    setAttachments((prev) =>
      prev.map((a) => (a.localId === pending.localId ? { ...a, status: "uploading", error: undefined } : a)),
    );
    try {
      const fileOut = await uploadFile(conversationId, pending.file, (percent) => {
        setAttachments((prev) =>
          prev.map((a) => (a.localId === pending.localId ? { ...a, progress: percent } : a)),
        );
      });
      setAttachments((prev) =>
        prev.map((a) => (a.localId === pending.localId ? { ...a, status: "done", fileOut } : a)),
      );
    } catch (err) {
      const detail = err instanceof ApiError ? err.message : "Upload failed.";
      setAttachments((prev) =>
        prev.map((a) => (a.localId === pending.localId ? { ...a, status: "error", error: detail } : a)),
      );
    }
  }

  function handleFileSelect(e: ChangeEvent<HTMLInputElement>) {
    const files = Array.from(e.target.files ?? []);
    e.target.value = ""; // allow re-selecting the same file later
    for (const file of files) {
      const pending: PendingAttachment = {
        localId: nextLocalId(),
        file,
        status: "uploading",
        progress: 0,
      };
      setAttachments((prev) => [...prev, pending]);
      void runUpload(pending);
    }
  }

  function removeAttachment(localId: string) {
    setAttachments((prev) => prev.filter((a) => a.localId !== localId));
  }

  async function sendMessage(content: string, fileIds: string[]) {
    setSending(true);
    setError(null);
    setStreamingMessage(null);

    try {
      await streamMessage(conversationId, content, fileIds, {
        onUserMessage: (message) => setMessages((prev) => [...prev, message]),
        onToken: (delta) => {
          setStreamingMessage((prev) => ({
            id: prev?.id ?? "streaming",
            conversation_id: conversationId,
            role: "assistant",
            content: (prev?.content ?? "") + delta,
            attachments: [],
            created_at: prev?.created_at ?? new Date().toISOString(),
          }));
        },
        onDone: (message) => {
          setStreamingMessage(null);
          setMessages((prev) => [...prev, message]);
          // Bumps the sidebar's ordering (backend updates the conversation's `updated_at` on
          // every message).
          refreshConversations();
        },
        onError: (detail) => setError(detail),
      });
      setLastAttempt(null);
      setAttachments([]);
    } catch (err) {
      setStreamingMessage(null);
      setError(err instanceof ApiError ? err.message : "Failed to send message.");
      setLastAttempt({ content, fileIds });
    } finally {
      setSending(false);
    }
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const trimmed = input.trim();
    if (!trimmed || sending) return;
    if (attachments.some((a) => a.status === "uploading")) return;

    const fileIds = attachments
      .filter((a) => a.status === "done" && a.fileOut)
      .map((a) => a.fileOut!.id);

    setInput("");
    await sendMessage(trimmed, fileIds);
  }

  async function handleRetry() {
    if (!lastAttempt) return;
    await sendMessage(lastAttempt.content, lastAttempt.fileIds);
  }

  const hasUploadingAttachment = attachments.some((a) => a.status === "uploading");

  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      <div className="flex-1 space-y-4 overflow-y-auto px-4 py-6">
        {loadingHistory && <p className="text-sm text-neutral-500">Loading messages…</p>}
        {historyError && <p className="text-sm text-red-500">{historyError}</p>}
        {!loadingHistory && !historyError && messages.length === 0 && (
          <p className="text-sm text-neutral-500">Say something to start the conversation.</p>
        )}
        {messages.map((message) => (
          <MessageBubble key={message.id} message={message} />
        ))}
        {sending && !streamingMessage && (
          <div className="flex justify-start">
            <div className="rounded-2xl bg-neutral-100 px-4 py-2 text-sm text-neutral-500 dark:bg-neutral-800">
              Assistant is thinking…
            </div>
          </div>
        )}
        {streamingMessage && <MessageBubble message={streamingMessage} />}
        <div ref={bottomRef} />
      </div>

      {error && (
        <div className="flex items-center justify-between gap-3 border-t border-red-200 bg-red-50 px-4 py-2 text-sm text-red-600 dark:border-red-900 dark:bg-red-950 dark:text-red-400">
          <span>{error}</span>
          {lastAttempt && (
            <button
              type="button"
              onClick={handleRetry}
              disabled={sending}
              className="shrink-0 rounded-md border border-current px-2 py-1 text-xs font-medium disabled:opacity-50"
            >
              Retry
            </button>
          )}
        </div>
      )}

      {attachments.length > 0 && (
        <div className="flex flex-wrap gap-2 border-t border-neutral-200 px-4 pt-3 dark:border-neutral-800">
          {attachments.map((a) => (
            <div
              key={a.localId}
              className="flex items-center gap-2 rounded-md border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700"
            >
              <span className="max-w-40 truncate">{a.file.name}</span>
              {a.status === "uploading" && <span className="text-neutral-500">{a.progress}%</span>}
              {a.status === "error" && (
                <button
                  type="button"
                  onClick={() => void runUpload(a)}
                  className="text-red-500 underline"
                  title={a.error}
                >
                  Retry
                </button>
              )}
              <button
                type="button"
                onClick={() => removeAttachment(a.localId)}
                aria-label={`Remove ${a.file.name}`}
                className="text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200"
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}

      <form
        onSubmit={handleSubmit}
        className="flex gap-2 border-t border-neutral-200 p-4 dark:border-neutral-800"
      >
        <input
          ref={fileInputRef}
          type="file"
          multiple
          onChange={handleFileSelect}
          accept="image/*,.pdf,.doc,.docx,.xls,.xlsx"
          className="hidden"
        />
        <button
          type="button"
          onClick={() => fileInputRef.current?.click()}
          disabled={sending}
          title="Attach a file"
          aria-label="Attach a file"
          className="rounded-md border border-neutral-300 px-3 py-2 text-sm disabled:opacity-60 dark:border-neutral-700"
        >
          +
        </button>
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
          disabled={sending || !input.trim() || hasUploadingAttachment}
          className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-60 dark:bg-white dark:text-neutral-900"
        >
          {sending ? "Sending…" : "Send"}
        </button>
      </form>
    </div>
  );
}
