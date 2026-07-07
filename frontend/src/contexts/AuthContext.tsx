"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { getMe, logout as apiLogout, type User } from "@/lib/auth";

interface AuthContextValue {
  user: User | null;
  /** True until the initial GET /auth/me call resolves (one way or the other). */
  loading: boolean;
  /** Re-checks GET /auth/me and updates `user`. Call after login/signup succeeds. */
  refreshUser: () => Promise<User | null>;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  const refreshUser = useCallback(async () => {
    try {
      const me = await getMe();
      setUser(me);
      return me;
    } catch {
      setUser(null);
      return null;
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // Fetch-on-mount pattern (checks GET /auth/me once when the provider mounts). The eventual
    // setUser/setLoading calls happen after an await inside refreshUser, but
    // eslint-plugin-react-hooks 7's set-state-in-effect rule still flags the call site here since
    // it traces into invoked functions - disabled deliberately, see the c/[id] page for the same
    // rationale.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    refreshUser();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const logout = useCallback(async () => {
    try {
      await apiLogout();
    } finally {
      setUser(null);
    }
  }, []);

  return (
    <AuthContext.Provider value={{ user, loading, refreshUser, logout }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within an AuthProvider");
  return ctx;
}
