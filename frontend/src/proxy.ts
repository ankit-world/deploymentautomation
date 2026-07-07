import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

// Route gate for the App Router.
//
// NOTE for future sessions: this file is named `proxy.ts` (not `middleware.ts`) and exports a
// function named `proxy` (not `middleware`) because the Next.js version this app was scaffolded
// with (16.x) renamed the `middleware` file convention to `proxy` — `middleware.ts` is
// deprecated. See node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/
// proxy.md if this trips you up; don't "fix" this back to middleware.ts.
//
// Why a presence-only cookie check is the right call here (per the session 03 brief's prompt to
// document this judgment call):
//
// The backend's `access_token`/`refresh_token` cookies are httpOnly, which only means
// document.cookie / client-side JS can never read them (XSS mitigation) — it does NOT mean
// server-side code is blind to them. Proxy runs server-side (Node.js runtime as of Next 16) and
// receives the raw `Cookie` header on every request, so `request.cookies.get(...)` sees httpOnly
// cookies exactly like any other cookie. What proxy *can't* do cheaply is validate the JWT's
// signature/expiry: that requires either duplicating JWT_SECRET into the frontend's environment
// (an unwanted trust-boundary leak — this secret should stay backend-only) or making a network
// call to the backend on every single navigation (real latency on every page load). So this is a
// deliberate, documented compromise:
//
//   1. Proxy checks *presence* of the `access_token` cookie only, and redirects to /login if
//      it's absent. This covers the common case (never logged in / explicitly logged out) without
//      a network round trip and without leaking the JWT secret client-side.
//   2. Real validation (expired or tampered token) is handled by the actual API calls the page
//      makes — the backend's `get_current_user` dependency (backend/app/dependencies.py) decodes
//      and verifies every request regardless of what proxy thinks. `AuthContext` (see
//      src/contexts/AuthContext.tsx) calls `GET /auth/me` on mount and treats any 401 (even after
//      an attempted `/auth/refresh`) as "not authenticated," redirecting client-side. So an
//      expired-but-present cookie still gets caught, just one render later than a cookie that's
//      missing outright.
//
// This two-layer approach (cheap optimistic check in proxy + authoritative check via the real
// API) mirrors the pattern Next.js's own authentication guide recommends for stateless sessions.
// See docs/ARCHITECTURE.md's Frontend section for a copy of this reasoning.
const PUBLIC_PATHS = ["/login", "/signup"];

export function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const isPublicPath = PUBLIC_PATHS.some(
    (path) => pathname === path || pathname.startsWith(`${path}/`),
  );
  const hasAccessToken = request.cookies.has("access_token");

  if (!isPublicPath && !hasAccessToken) {
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("from", pathname);
    return NextResponse.redirect(loginUrl);
  }

  if (isPublicPath && hasAccessToken) {
    return NextResponse.redirect(new URL("/", request.url));
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
