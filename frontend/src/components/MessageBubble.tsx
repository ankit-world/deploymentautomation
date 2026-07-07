import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import type { Message } from "@/lib/api";
import Attachment from "@/components/Attachment";

export default function MessageBubble({ message }: { message: Message }) {
  const isUser = message.role === "user";
  return (
    <div className={`flex ${isUser ? "justify-end" : "justify-start"}`}>
      <div
        className={`max-w-[75%] rounded-2xl px-4 py-2 text-sm ${
          isUser
            ? "bg-neutral-900 text-white dark:bg-white dark:text-neutral-900"
            : "bg-neutral-100 text-neutral-900 dark:bg-neutral-800 dark:text-neutral-100"
        }`}
      >
        {isUser ? (
          <p className="whitespace-pre-wrap">{message.content}</p>
        ) : message.content ? (
          <div className="prose prose-sm prose-neutral max-w-none dark:prose-invert prose-pre:bg-neutral-900 prose-pre:text-neutral-100 prose-p:my-1 prose-ul:my-1 prose-ol:my-1">
            <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeHighlight]}>
              {message.content}
            </ReactMarkdown>
          </div>
        ) : (
          // Assistant message row exists (e.g. mid-stream before the first token) but has no
          // text yet; render nothing rather than an empty markdown tree.
          <span className="opacity-0">&nbsp;</span>
        )}

        {message.attachments.length > 0 && (
          <div className="mt-2 space-y-2 border-t border-current/20 pt-2">
            {message.attachments.map((attachment) => (
              <Attachment
                key={attachment.id}
                conversationId={message.conversation_id}
                attachment={attachment}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
