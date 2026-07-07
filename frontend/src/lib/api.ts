// Shared API client for the FastAPI backend.
//
// Auth is entirely cookie-based (httpOnly `access_token` / `refresh_token` set by the backend
// on signup/login/refresh) — there is no bearer token to manage here. Every request just needs
// `credentials: 'include'` so the browser attaches/stores those cookies. See
// docs/ARCHITECTURE.md's Frontend section for the cross-port cookie note (why this works with
// frontend on :3000 and backend on :8000 in local dev).

export const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

export interface User {
  id: string;
  email: string;
  name: string;
  created_at: string;
}

export interface Conversation {
  id: string;
  title: string;
  created_at: string;
  updated_at: string;
}

export interface FileAttachmentSummary {
  id: string;
  filename: string;
  mimetype: string;
  kind: string;
  size: number;
}

export interface Message {
  id: string;
  conversation_id: string;
  role: "user" | "assistant";
  content: string;
  attachments: FileAttachmentSummary[];
  created_at: string;
}

export class ApiError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

async function rawFetch(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${API_BASE_URL}${path}`, {
    ...init,
    credentials: "include",
    headers: {
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...init.headers,
    },
  });
}

// Coalesce concurrent refresh attempts into a single in-flight request so a burst of 401s
// (e.g. several components fetching on mount) doesn't fire /auth/refresh multiple times.
let refreshPromise: Promise<boolean> | null = null;

async function tryRefresh(): Promise<boolean> {
  if (!refreshPromise) {
    refreshPromise = rawFetch("/auth/refresh", { method: "POST" })
      .then((res) => res.ok)
      .catch(() => false)
      .finally(() => {
        refreshPromise = null;
      });
  }
  return refreshPromise;
}

async function parseErrorDetail(res: Response): Promise<string> {
  try {
    const body = await res.json();
    if (typeof body?.detail === "string") return body.detail;
  } catch {
    // response wasn't JSON; fall through to statusText
  }
  return res.statusText || `Request failed with status ${res.status}`;
}

/**
 * JSON fetch wrapper. On a 401 it transparently attempts POST /auth/refresh once (to renew a
 * short-lived expired access token via the longer-lived refresh cookie) and retries the original
 * request. If refresh also fails, throws ApiError(401) so callers can redirect to /login.
 */
export async function apiFetch<T>(
  path: string,
  init: RequestInit = {},
  opts: { skipRefresh?: boolean } = {},
): Promise<T> {
  let res = await rawFetch(path, init);

  if (res.status === 401 && !opts.skipRefresh && path !== "/auth/refresh") {
    const refreshed = await tryRefresh();
    if (refreshed) {
      res = await rawFetch(path, init);
    }
  }

  if (!res.ok) {
    throw new ApiError(res.status, await parseErrorDetail(res));
  }

  if (res.status === 204) {
    return undefined as T;
  }

  return (await res.json()) as T;
}

export { tryRefresh };
