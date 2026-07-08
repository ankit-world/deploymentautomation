"""Async Redis client, used for per-user chat rate limiting (and, from a later session, the
refresh-token/logout blacklist — see docs/ARCHITECTURE.md "Redis").

This dev machine has no local Redis server and no Docker-based one is assumed to be running by
default, so when `REDIS_URL` is unset we fall back to `fakeredis`'s async client, which
implements the same `redis.asyncio` interface (INCR, EXPIRE, etc.) in-memory. The rate-limit
code in app/core/rate_limit.py is written against that shared interface, so nothing changes
there once real Redis/ElastiCache exists (session 09) — only this factory swaps implementations.
"""

from redis.asyncio import Redis

from app.core.config import settings

_client: Redis | None = None


def _create_client() -> Redis:
    if settings.redis_url:
        return Redis.from_url(settings.redis_url, decode_responses=True)

    import fakeredis.aioredis as fakeredis_async

    return fakeredis_async.FakeRedis(decode_responses=True)


async def connect_redis() -> None:
    """Called from app.main's lifespan on startup — moves client creation from lazy (on first
    get_redis() call) to explicit, mirroring app.core.db.connect_db(). Real Redis/fakeredis
    client construction is non-blocking (no network I/O happens until a command is actually
    sent), so this is safe to run in tests' real lifespan same as connect_db() is."""
    global _client
    if _client is None:
        _client = _create_client()


async def get_redis() -> Redis:
    """FastAPI dependency. A single client/connection pool is reused across requests. Falls back
    to lazy creation if somehow called before connect_redis() ran (shouldn't happen in normal
    FastAPI request handling, which always runs after lifespan startup completes)."""
    global _client
    if _client is None:
        _client = _create_client()
    return _client


async def close_redis() -> None:
    """Called from app.main's lifespan on shutdown for the same graceful-SIGTERM reason as
    app.core.db.close_db(). No-ops if get_redis() was never called (e.g. a task that shut down
    before handling any chat request) — nothing to close."""
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
