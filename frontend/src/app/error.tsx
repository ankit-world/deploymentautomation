"use client";

import { useEffect } from "react";
import Link from "next/link";

// Production-audit follow-up: this app had no error boundary at all — an unhandled render/render-
// time error in any route would fall through to Next's bare default crash screen instead of
// something consistent with the rest of the app's look, and nothing logged it client-side.
// Must be a Client Component (Next.js requirement for error.tsx) and catches errors in the route
// segment tree below it, not errors in layout.tsx itself — see global-error.tsx for that case.
export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    // No client-side logging pipeline exists yet; this is at least visible in the browser
    // console / any error-tracking tool that hooks console.error.
    console.error("Unhandled render error:", error);
  }, [error]);

  return (
    <div className="flex min-h-screen flex-1 flex-col items-center justify-center gap-4 px-4 text-center">
      <h1 className="text-2xl font-semibold">Something went wrong</h1>
      <p className="max-w-sm text-sm text-neutral-500">
        An unexpected error occurred. You can try again, or head back to the home page.
      </p>
      <div className="flex gap-2">
        <button
          onClick={reset}
          className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white dark:bg-white dark:text-neutral-900"
        >
          Try again
        </button>
        <Link
          href="/"
          className="rounded-md border border-neutral-300 px-4 py-2 text-sm font-medium dark:border-neutral-700"
        >
          Go home
        </Link>
      </div>
    </div>
  );
}
