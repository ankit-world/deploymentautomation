"use client";

import { useEffect } from "react";

// Catches errors in the root layout itself (error.tsx can't - it renders *inside* the layout it
// would need to replace). Must render its own <html>/<body>: this fully replaces the root layout
// when it's active, so it can't assume anything in layout.tsx (fonts, providers) still works.
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error("Unhandled root layout error:", error);
  }, [error]);

  return (
    <html lang="en">
      <body>
        <div style={{ display: "flex", minHeight: "100vh", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: "1rem", padding: "1rem", textAlign: "center", fontFamily: "system-ui, sans-serif" }}>
          <h1 style={{ fontSize: "1.5rem", fontWeight: 600 }}>Something went wrong</h1>
          <p style={{ maxWidth: "24rem", fontSize: "0.875rem", color: "#737373" }}>
            An unexpected error occurred while loading the app. Please try again.
          </p>
          <button
            onClick={reset}
            style={{ borderRadius: "0.375rem", backgroundColor: "#171717", color: "white", padding: "0.5rem 1rem", fontSize: "0.875rem", fontWeight: 500, border: "none", cursor: "pointer" }}
          >
            Try again
          </button>
        </div>
      </body>
    </html>
  );
}
