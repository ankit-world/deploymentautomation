import type { Message } from "@/lib/api";

export default function MessageBubble({ message }: { message: Message }) {
  const isUser = message.role === "user";
  return (
    <div className={`flex ${isUser ? "justify-end" : "justify-start"}`}>
      <div
        className={`max-w-[75%] whitespace-pre-wrap rounded-2xl px-4 py-2 text-sm ${
          isUser
            ? "bg-neutral-900 text-white dark:bg-white dark:text-neutral-900"
            : "bg-neutral-100 text-neutral-900 dark:bg-neutral-800 dark:text-neutral-100"
        }`}
      >
        {message.content}
        {message.attachments.length > 0 && (
          <ul className="mt-2 space-y-1 border-t border-white/20 pt-2 text-xs opacity-80">
            {message.attachments.map((attachment) => (
              <li key={attachment.id}>{attachment.filename}</li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
