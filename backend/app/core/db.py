from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase

from app.core.config import settings

_client: AsyncIOMotorClient | None = None
_db: AsyncIOMotorDatabase | None = None


async def connect_db() -> None:
    """Called from app.main's lifespan on startup. Only constructs the client — Motor is lazy,
    so this performs no network I/O itself (the first real query does, whenever that happens).
    Deliberately async (even though nothing here needs awaiting yet) for interface symmetry with
    close_db() and connect_redis()/close_redis(), and so a future real connectivity check can be
    added here without changing the call site.

    No ping here: tests drive the app via `with TestClient(app):` (see tests/conftest.py), which
    runs this module's real lifespan on every one of the 36 tests (function-scoped fixture) —
    `app.dependency_overrides` only intercepts `Depends()`-injected calls during request
    handling, not code the lifespan function calls directly, so a real ping would bypass the test
    suite's mocked DB entirely and hang against the default `mongodb://localhost:27017` with
    Motor's ~30s server-selection timeout, once per test.
    """
    global _client, _db
    _client = AsyncIOMotorClient(settings.mongodb_uri)
    _db = _client[settings.mongodb_db_name]


async def close_db() -> None:
    """Called from app.main's lifespan on shutdown so the connection pool is torn down
    gracefully on SIGTERM (ECS sends this on every rolling redeploy) instead of the socket just
    being dropped. Motor's close() is itself synchronous, not a coroutine — this wrapper is
    async only so the lifespan can `await` all its connect/close calls uniformly."""
    if _client is not None:
        _client.close()


async def get_db() -> AsyncIOMotorDatabase:
    assert _db is not None, "connect_db() must run (via app.main's lifespan) before get_db()"
    return _db
