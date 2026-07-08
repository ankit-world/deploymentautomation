from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase

from app.core.config import settings

_client = AsyncIOMotorClient(settings.mongodb_uri)
_db = _client[settings.mongodb_db_name]


async def get_db() -> AsyncIOMotorDatabase:
    return _db


def close_db() -> None:
    """Called from app.main's lifespan on shutdown so the connection pool is torn down
    gracefully on SIGTERM (ECS sends this on every rolling redeploy) instead of the socket just
    being dropped. Motor's close() is synchronous, not a coroutine — do not await it.

    No corresponding startup ping: tests drive the app via `with TestClient(app):` (see
    tests/conftest.py), which runs this module's real lifespan on every test — but
    `app.dependency_overrides` only intercepts `Depends()`-injected calls during request
    handling, not code the lifespan function calls directly, so a real ping here would bypass
    the test suite's mocked DB entirely and try to reach the default `mongodb://localhost:27017`
    with Motor's ~30s server-selection timeout, once per test.
    """
    _client.close()
