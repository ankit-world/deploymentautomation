import { apiFetch, type User } from "./api";

export async function signup(email: string, password: string, name: string): Promise<User> {
  return apiFetch<User>(
    "/auth/signup",
    { method: "POST", body: JSON.stringify({ email, password, name }) },
    { skipRefresh: true },
  );
}

export async function login(email: string, password: string): Promise<User> {
  return apiFetch<User>(
    "/auth/login",
    { method: "POST", body: JSON.stringify({ email, password }) },
    { skipRefresh: true },
  );
}

export async function logout(): Promise<void> {
  await apiFetch<void>("/auth/logout", { method: "POST" }, { skipRefresh: true });
}

export async function getMe(): Promise<User> {
  return apiFetch<User>("/auth/me");
}

export type { User };
