"use client";

import { useEffect } from "react";
import type { ReactNode } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import { ConversationsProvider } from "@/contexts/ConversationsContext";
import Sidebar from "@/components/Sidebar";

// Client-side half of the auth gate. src/proxy.ts already redirects to /login when the
// `access_token` cookie is entirely absent, but it can't validate the token's signature/expiry
// (see the comment in proxy.ts). This layout is the authoritative check: it waits for
// `GET /auth/me` (via AuthProvider) to resolve, and redirects to /login if that comes back
// unauthenticated (covers an expired-but-still-present cookie, revoked user, etc).
export default function ProtectedLayout({ children }: { children: ReactNode }) {
  const { user, loading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!loading && !user) {
      router.replace("/login");
    }
  }, [loading, user, router]);

  if (loading) {
    return (
      <div className="flex min-h-screen flex-1 items-center justify-center">
        <p className="text-sm text-neutral-500">Loading…</p>
      </div>
    );
  }

  if (!user) {
    // Redirect above is in flight; render nothing rather than flashing protected content.
    return null;
  }

  return (
    <ConversationsProvider>
      <div className="flex h-screen">
        <Sidebar />
        <main className="flex flex-1 flex-col overflow-hidden">{children}</main>
      </div>
    </ConversationsProvider>
  );
}
