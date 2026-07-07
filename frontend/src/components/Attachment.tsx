"use client";

import { useEffect, useState } from "react";
import type { FileAttachmentSummary } from "@/lib/api";
import { downloadFile, fetchFileBlob } from "@/lib/files";

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let value = bytes / 1024;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${value.toFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}`;
}

const KIND_LABEL: Record<string, string> = {
  pdf: "PDF",
  docx: "Word",
  xlsx: "Excel",
  other: "File",
};

function DocIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-6 w-6 shrink-0" fill="none" stroke="currentColor" strokeWidth={1.5}>
      <path
        d="M6 2.75h8.25L19 7.5V21a.25.25 0 0 1-.25.25H6a.25.25 0 0 1-.25-.25V3a.25.25 0 0 1 .25-.25Z"
        strokeLinejoin="round"
      />
      <path d="M14 2.75V7.5h4.75" strokeLinejoin="round" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth={1.75}>
      <path d="M12 3v12m0 0-4-4m4 4 4-4M4 20h16" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/** Shared download button + busy/error state, used by both the image and document cards. */
function DownloadButton({
  conversationId,
  attachment,
}: {
  conversationId: string;
  attachment: FileAttachmentSummary;
}) {
  const [state, setState] = useState<"idle" | "downloading" | "error">("idle");

  async function handleDownload() {
    setState("downloading");
    try {
      await downloadFile(conversationId, attachment.id, attachment.filename);
      setState("idle");
    } catch {
      setState("error");
    }
  }

  return (
    <button
      type="button"
      onClick={handleDownload}
      disabled={state === "downloading"}
      title={state === "error" ? "Download failed, click to retry" : "Download"}
      className="inline-flex items-center gap-1 rounded-md border border-current/20 px-2 py-1 text-xs font-medium opacity-80 hover:opacity-100 disabled:opacity-50"
    >
      <DownloadIcon />
      {state === "downloading" ? "Downloading…" : state === "error" ? "Retry download" : "Download"}
    </button>
  );
}

function ImageAttachment({
  conversationId,
  attachment,
}: {
  conversationId: string;
  attachment: FileAttachmentSummary;
}) {
  const [objectUrl, setObjectUrl] = useState<string | null>(null);
  const [error, setError] = useState(false);
  const [expanded, setExpanded] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let localUrl: string | null = null;
    fetchFileBlob(conversationId, attachment.id)
      .then((blob) => {
        if (cancelled) return;
        localUrl = URL.createObjectURL(blob);
        setObjectUrl(localUrl);
      })
      .catch(() => {
        if (!cancelled) setError(true);
      });
    return () => {
      cancelled = true;
      if (localUrl) URL.revokeObjectURL(localUrl);
    };
  }, [conversationId, attachment.id]);

  return (
    <div className="space-y-1">
      {error && (
        <p className="text-xs text-red-500">Couldn&apos;t load preview for {attachment.filename}.</p>
      )}
      {!error && !objectUrl && (
        <div className="flex h-24 w-32 animate-pulse items-center justify-center rounded-lg bg-black/10 text-xs opacity-60 dark:bg-white/10">
          Loading…
        </div>
      )}
      {objectUrl && (
        <button
          type="button"
          onClick={() => setExpanded(true)}
          className="block overflow-hidden rounded-lg border border-current/10"
        >
          {/* eslint-disable-next-line @next/next/no-img-element -- object URL from an
              authenticated blob fetch, not a static/remote asset next/image can optimize */}
          <img
            src={objectUrl}
            alt={attachment.filename}
            className="max-h-48 max-w-64 object-cover"
          />
        </button>
      )}
      <div className="flex items-center justify-between gap-2 text-xs opacity-80">
        <span className="truncate">{attachment.filename}</span>
        <DownloadButton conversationId={conversationId} attachment={attachment} />
      </div>

      {expanded && objectUrl && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-6"
          onClick={() => setExpanded(false)}
        >
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={objectUrl}
            alt={attachment.filename}
            className="max-h-full max-w-full rounded-lg object-contain"
            onClick={(e) => e.stopPropagation()}
          />
          <button
            type="button"
            onClick={() => setExpanded(false)}
            aria-label="Close"
            className="absolute right-6 top-6 rounded-full bg-white/90 px-3 py-1 text-sm font-medium text-neutral-900"
          >
            Close
          </button>
        </div>
      )}
    </div>
  );
}

function DocumentAttachment({
  conversationId,
  attachment,
}: {
  conversationId: string;
  attachment: FileAttachmentSummary;
}) {
  return (
    <div className="flex items-center gap-3 rounded-lg border border-current/15 bg-black/5 px-3 py-2 dark:bg-white/5">
      <DocIcon />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium">{attachment.filename}</p>
        <p className="text-xs opacity-70">
          {KIND_LABEL[attachment.kind] ?? "File"} · {formatBytes(attachment.size)}
        </p>
      </div>
      <DownloadButton conversationId={conversationId} attachment={attachment} />
    </div>
  );
}

export default function Attachment({
  conversationId,
  attachment,
}: {
  conversationId: string;
  attachment: FileAttachmentSummary;
}) {
  if (attachment.kind === "image") {
    return <ImageAttachment conversationId={conversationId} attachment={attachment} />;
  }
  return <DocumentAttachment conversationId={conversationId} attachment={attachment} />;
}
