"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import { useConversations } from "@/contexts/ConversationsContext";
import { createConversation } from "@/lib/conversations";

export default function Sidebar() {
  const { user, logout } = useAuth();
  const { conversations, loading, refresh } = useConversations();
  const pathname = usePathname();
  const router = useRouter();
  const [creating, setCreating] = useState(false);

  async function handleNewConversation() {
    setCreating(true);
    try {
      const conversation = await createConversation();
      await refresh();
      router.push(`/c/${conversation.id}`);
    } finally {
      setCreating(false);
    }
  }

  return (
    <aside className="flex h-screen w-72 shrink-0 flex-col border-r border-neutral-200 dark:border-neutral-800">
      <div className="p-3">
        <button
          onClick={handleNewConversation}
          disabled={creating}
          className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm font-medium hover:bg-neutral-100 disabled:opacity-60 dark:border-neutral-700 dark:hover:bg-neutral-900"
        >
          {creating ? "Creating…" : "+ New conversation"}
        </button>
      </div>

      <nav className="flex-1 overflow-y-auto px-2">
        {loading && <p className="px-2 py-1 text-sm text-neutral-500">Loading…</p>}
        {!loading && conversations.length === 0 && (
          <p className="px-2 py-1 text-sm text-neutral-500">No conversations yet.</p>
        )}
        <ul className="space-y-0.5">
          {conversations.map((conversation) => {
            const href = `/c/${conversation.id}`;
            const isActive = pathname === href;
            return (
              <li key={conversation.id}>
                <Link
                  href={href}
                  className={`block truncate rounded-md px-3 py-2 text-sm ${
                    isActive
                      ? "bg-neutral-200 font-medium dark:bg-neutral-800"
                      : "hover:bg-neutral-100 dark:hover:bg-neutral-900"
                  }`}
                >
                  {conversation.title || "Untitled conversation"}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>

      <div className="border-t border-neutral-200 p-3 text-sm dark:border-neutral-800">
        <p className="truncate font-medium">{user?.name}</p>
        <p className="truncate text-neutral-500">{user?.email}</p>
        <button
          onClick={() => logout().then(() => router.push("/login"))}
          className="mt-2 text-sm text-neutral-500 underline hover:text-neutral-900 dark:hover:text-neutral-100"
        >
          Log out
        </button>
      </div>
    </aside>
  );
}
