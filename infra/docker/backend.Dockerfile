# Multi-stage build for the FastAPI backend (see docs/ARCHITECTURE.md "Backend (FastAPI)").
#
# Build context is the REPO ROOT (see infra/docker/docker-compose.yml's `build.context: ../..`),
# not backend/ — so every COPY below is rooted at "backend/...". This lets the Dockerfile live
# next to frontend.Dockerfile under infra/docker/ while still only pulling in the backend/
# subtree (root .dockerignore excludes everything else).
#
# Python 3.12 to match docs/ARCHITECTURE.md's documented backend runtime (the local dev venv
# happens to be 3.11, but that's just what was on this machine when the venv was created —
# requirements.txt has no pin forcing 3.11, and 3.12 is what production targets).

FROM python:3.12-slim AS builder
WORKDIR /build

# build-essential covers the rare case a dependency has no manylinux wheel for the target arch
# (e.g. building on/for arm64) and needs to compile from source. Not needed in the runtime stage.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# --- Runtime stage: no compiler, no pip cache, just the venv + app code ---
FROM python:3.12-slim AS runtime
WORKDIR /app

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --system app && useradd --system --gid app --home /app app

COPY --from=builder /opt/venv /opt/venv
COPY backend/app ./app

# UPLOAD_DIR defaults to "uploads" (relative to cwd, see app/core/config.py); docker-compose.yml
# overrides it to /data/uploads, the mount point of a named volume, so files survive container
# restarts/recreates (see storage.py's LocalDiskStorage). Pre-create BOTH paths and chown them to
# the non-root `app` user here, before `docker compose` ever mounts the volume: Docker seeds a
# brand-new named volume from whatever already exists at its mount point in the image (including
# ownership) — skip this and the volume mount point comes up owned by root, and LocalDiskStorage
# (running as `app`) gets a PermissionError on its first `mkdir`/`write_bytes` under it.
RUN mkdir -p /app/uploads /data/uploads && chown -R app:app /app /data/uploads

USER app

EXPOSE 8000

# Plain uvicorn (not gunicorn+uvicorn workers) — sufficient for local docker-compose e2e
# verification (session 05). docs/ARCHITECTURE.md notes Gunicorn fronts Uvicorn in prod; that
# harness is an ECS/production concern, deferred to session 08.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
