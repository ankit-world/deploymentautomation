import fakeredis.aioredis as fakeredis_async
import pytest
from fastapi.testclient import TestClient
from mongomock_motor import AsyncMongoMockClient

from app.core.db import get_db
from app.core.redis_client import get_redis
from app.main import app
from app.services.storage import LocalDiskStorage, get_storage


@pytest.fixture()
def client(tmp_path):
    mock_db = AsyncMongoMockClient()["test_db"]
    fake_redis = fakeredis_async.FakeRedis(decode_responses=True)
    local_storage = LocalDiskStorage(tmp_path / "uploads")

    async def override_get_db():
        return mock_db

    async def override_get_redis():
        return fake_redis

    def override_get_storage():
        return local_storage

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_redis] = override_get_redis
    app.dependency_overrides[get_storage] = override_get_storage
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()
