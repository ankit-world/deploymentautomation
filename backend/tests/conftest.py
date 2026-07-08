import asyncio

import fakeredis.aioredis as fakeredis_async
import pytest
from fastapi.testclient import TestClient
from mongomock_motor import AsyncMongoMockClient

from app.core.db import get_db
from app.core.redis_client import get_redis
from app.main import app
from app.services import llm
from app.services.storage import LocalDiskStorage, get_storage


@pytest.fixture()
def client(tmp_path):
    mock_db = AsyncMongoMockClient()["test_db"]
    # Mirrors the real unique index backend/scripts/ensure_indexes.py creates on Atlas — without
    # it here too, tests can't exercise the DuplicateKeyError race-condition handling in
    # app/routers/auth.py's signup(), since mongomock enforces nothing without an actual index.
    # No running event loop exists yet at this point in fixture setup, so asyncio.run() is safe.
    asyncio.run(mock_db.users.create_index("email", unique=True))
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
        # Exposed for tests that need to reach into the mock DB directly (e.g. simulating a
        # check-then-act race by inserting a doc "behind the API's back" — see
        # test_signup_race_condition_caught_by_unique_index in test_auth.py).
        test_client.mock_db = mock_db
        yield test_client
    app.dependency_overrides.clear()


@pytest.fixture()
def mock_llm_stream(monkeypatch):
    """Replaces the real LLM call with a deterministic fake, so tests never hit the network.
    Shared across test_messages.py and test_metrics.py."""
    captured_messages = {}

    async def fake_stream(messages, model=None, on_usage=None):
        captured_messages["messages"] = messages
        for token in ["Hello", ", ", "world", "!"]:
            yield token
        if on_usage is not None:
            on_usage({"prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16})

    monkeypatch.setattr(llm, "stream_chat_completion", fake_stream)
    return captured_messages
