"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { listConversations, type Conversation } from "@/lib/conversations";

interface ConversationsContextValue {
  conversations: Conversation[];
  loading: boolean;
  /** Re-fetches GET /conversations. Call after creating a conversation or sending a message
   * (the backend bumps `updated_at` on send, which is what the list is sorted by). */
  refresh: () => Promise<void>;
}

const ConversationsContext = createContext<ConversationsContextValue | undefined>(undefined);

export function ConversationsProvider({ children }: { children: ReactNode }) {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const data = await listConversations();
      setConversations(data);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return (
    <ConversationsContext.Provider value={{ conversations, loading, refresh }}>
      {children}
    </ConversationsContext.Provider>
  );
}

export function useConversations(): ConversationsContextValue {
  const ctx = useContext(ConversationsContext);
  if (!ctx) throw new Error("useConversations must be used within a ConversationsProvider");
  return ctx;
}
