import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.core.config import settings
from app.core.logging_config import setup_logging

# Must run before any other app.* module's logger is first used, so every log line (including
# ones emitted during router/service import, if any ever are) goes through the JSON formatter.
setup_logging(settings.log_level)

from app.core import metrics  # noqa: E402
from app.core.db import close_db, connect_db  # noqa: E402
from app.core.redis_client import close_redis, connect_redis  # noqa: E402
from app.core.security import ACCESS_TOKEN_TYPE, InvalidTokenError, decode_token  # noqa: E402
from app.routers import auth, conversations, files, messages  # noqa: E402

logger = logging.getLogger(__name__)


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


def _resolve_user_id(request: Request) -> str | None:
    """Best-effort user identity for logging only — not an auth check (get_current_user, via
    Depends, is what actually enforces auth on protected routes). Never raises: an absent,
    expired, or malformed access_token cookie just means the log line has no user_id, same as an
    unauthenticated request genuinely would."""
    token = request.cookies.get("access_token")
    if token is None:
        return None
    try:
        return decode_token(token, ACCESS_TOKEN_TYPE)
    except InvalidTokenError:
        return None


@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    """Records one RequestCount/RequestDuration/error-count metric (app/core/metrics.py) and one
    structured JSON log line (app/core/logging_config.py) per HTTP request. Skips /health: the
    ALB polls it roughly every 30s per target, and that traffic is infrastructure noise, not
    application traffic worth counting/logging alongside real usage.

    Uses `request.scope["route"].path` (the templated path, e.g.
    "/conversations/{conversation_id}/messages") rather than `request.url.path` (which would
    contain real IDs) for the *metric* — using the raw path would make every distinct
    conversation/file id its own dimension value. The raw path is fine (and more useful) for the
    *log* line, which doesn't have metric cardinality concerns, so both are recorded.

    Also the global unhandled-exception handler — `@app.exception_handler(Exception)` looks like
    the idiomatic FastAPI way to do this, but it does NOT reliably fire when a `BaseHTTPMiddleware`
    (which `@app.middleware("http")` creates) is also registered, a known Starlette/FastAPI
    interaction gap — confirmed directly here, not assumed: an initial attempt using
    `@app.exception_handler(Exception)` let the raw exception propagate straight past it in
    testing. Catching it in this middleware's own try/except sidesteps the issue entirely, and
    conveniently means the request-completed metric/log line still fires for failures too (with
    the correct 500 status), not just successes.
    """
    if request.url.path == "/health":
        return await call_next(request)

    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception as exc:
        duration_ms = (time.perf_counter() - start) * 1000
        route = request.scope.get("route")
        route_path = route.path if route is not None else request.url.path
        logger.exception(
            "unhandled exception",
            exc_info=exc,
            extra={
                "event": "unhandled_exception",
                "method": request.method,
                "path": request.url.path,
                "user_id": _resolve_user_id(request),
            },
        )
        await metrics.record_request(route_path, request.method, 500, duration_ms)
        return JSONResponse(status_code=500, content={"detail": "Internal server error"})
    duration_ms = (time.perf_counter() - start) * 1000

    route = request.scope.get("route")
    route_path = route.path if route is not None else request.url.path
    await metrics.record_request(route_path, request.method, response.status_code, duration_ms)

    logger.info(
        "request completed",
        extra={
            "event": "request",
            "method": request.method,
            "path": request.url.path,
            "route": route_path,
            "status_code": response.status_code,
            "duration_ms": round(duration_ms, 2),
            "user_id": _resolve_user_id(request),
            "client_ip": request.client.host if request.client else None,
        },
    )

    return response
