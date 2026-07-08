import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

from app.core import metrics
from app.core.config import settings
from app.core.db import close_db, connect_db
from app.core.redis_client import close_redis, connect_redis
from app.routers import auth, conversations, files, messages


@asynccontextmanager
async def lifespan(app: FastAPI):
    await connect_db()
    await connect_redis()
    yield
    # ECS sends SIGTERM on every rolling redeploy (session 11 made these automatic on every
    # push to main) — close both connection pools gracefully instead of the socket just being
    # dropped. See connect_db()/connect_redis() for why there's no real connectivity check here,
    # just client construction.
    await close_db()
    await close_redis()


app = FastAPI(title="ChatGPT-style App API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.frontend_origin],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(conversations.router)
app.include_router(messages.router)
app.include_router(files.router)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    """Records one RequestCount/RequestDuration/error-count metric per HTTP request — see
    app/core/metrics.py. Skips /health: the ALB polls it roughly every 30s per target, and that
    traffic is infrastructure noise, not application traffic worth counting alongside real usage.

    Uses `request.scope["route"].path` (the templated path, e.g.
    "/conversations/{conversation_id}/messages") rather than `request.url.path` (which would
    contain real IDs) — using the raw path would make every distinct conversation/file id its
    own value, which is fine as a log property but would be a real problem if it were ever used
    as a metric dimension. Falls back to the raw path for genuinely unmatched routes (404s),
    which don't have a `route` in scope at all — cardinality risk here is bounded by "how many
    distinct nonexistent paths get requested," normally low outside of a scanning/attack burst.
    """
    if request.url.path == "/health":
        return await call_next(request)

    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = (time.perf_counter() - start) * 1000

    route = request.scope.get("route")
    route_path = route.path if route is not None else request.url.path
    await metrics.record_request(route_path, request.method, response.status_code, duration_ms)

    return response
