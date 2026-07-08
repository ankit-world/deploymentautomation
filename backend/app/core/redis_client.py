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


async def get_redis() -> Redis:
    """FastAPI dependency. A single client/connection pool is reused across requests."""
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
