import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Session 05 (Docker): traces the minimal production dependency set into `.next/standalone`
  // (a self-contained `server.js` + only the node_modules actually used) so the Docker runtime
  // stage doesn't need to copy the full node_modules tree — smaller image, faster builds. Only
  // affects `next build`/`next start` packaging; no effect on `next dev`.
  output: "standalone",
};

export default nextConfig;
