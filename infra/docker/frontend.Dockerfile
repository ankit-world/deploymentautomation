# Multi-stage build for the Next.js frontend (see docs/ARCHITECTURE.md "Frontend (Next.js)").
#
# Build context is the REPO ROOT (see infra/docker/docker-compose.yml's `build.context: ../..`),
# so every COPY below is rooted at "frontend/...".
#
# --- CRITICAL: NEXT_PUBLIC_API_URL is a browser-side, BUILD-TIME value ---
# frontend/src/lib/api.ts calls the backend directly from the browser (no Next.js server proxy):
#   export const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";
# Next.js inlines NEXT_PUBLIC_* vars into the client JS bundle during `next build`. Setting it in
# docker-compose.yml's `environment:` at container *runtime* would have NO effect on an
# already-built image. It must be a Docker build ARG, consumed below before `npm run build`.
#
# It must resolve to the HOST-PUBLISHED backend port (http://localhost:8000) — the browser runs
# on the host machine, not inside the Docker network, so the Docker-internal service name
# (http://backend:8000) would be unreachable from it. This is the mirror image of REDIS_URL in
# docker-compose.yml, which correctly *does* use the internal service name (redis://redis:6379)
# because Redis is read server-side, inside the backend container.

FROM node:22-slim AS deps
WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

FROM node:22-slim AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY frontend/ .

ARG NEXT_PUBLIC_API_URL=http://localhost:8000
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}

RUN npm run build

# --- Runtime stage: Next's `output: standalone` (frontend/next.config.ts) traces only the
# production deps actually used into .next/standalone/server.js, so this stage never needs the
# full node_modules tree — smaller image than a plain `next start` runtime would be.
FROM node:22-slim AS runtime
WORKDIR /app

ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN groupadd --system app && useradd --system --gid app --home /app app

COPY --from=builder /app/public ./public
COPY --from=builder --chown=app:app /app/.next/standalone ./
COPY --from=builder --chown=app:app /app/.next/static ./.next/static

USER app

EXPOSE 3000

CMD ["node", "server.js"]
