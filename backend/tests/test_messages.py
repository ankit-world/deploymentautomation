import json

from app.core.config import settings
from app.services import llm


def _signup(client, email="ivan@example.com"):
    resp = client.post(
        "/auth/signup", json={"email": email, "password": "hunter22", "name": "Ivan"}
    )
    assert resp.status_code == 201
    return resp.json()


def _create_conversation(client, title="Chat"):
    resp = client.post("/conversations", json={"title": title})
    assert resp.status_code == 201
    return resp.json()


def parse_sse(text: str) -> list[tuple[str, dict]]:
    events = []
    for block in text.strip("\n").split("\n\n"):
        if not block.strip():
            continue
        event_type = None
        data = None
        for line in block.splitlines():
            if line.startswith("event: "):
                event_type = line[len("event: ") :]
            elif line.startswith("data: "):
                data = json.loads(line[len("data: ") :])
        events.append((event_type, data))
    return events


# mock_llm_stream fixture now lives in conftest.py (shared with test_metrics.py).


def test_post_message_streams_sse_and_persists_both_messages(client, mock_llm_stream):
    _signup(client)
    conversation = _create_conversation(client)

    resp = client.post(
        f"/conversations/{conversation['id']}/messages", json={"content": "Hello there"}
    )
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")

    events = parse_sse(resp.text)
    event_types = [e[0] for e in events]
    assert event_types[0] == "user_message"
    assert "token" in event_types
    assert event_types[-1] == "done"

    user_event = next(e for e in events if e[0] == "user_message")
    assert user_event[1]["content"] == "Hello there"
    assert user_event[1]["role"] == "user"

    token_texts = "".join(e[1]["content"] for e in events if e[0] == "token")
    assert token_texts == "Hello, world!"

    done_event = next(e for e in events if e[0] == "done")
    assert done_event[1]["role"] == "assistant"
    assert done_event[1]["content"] == "Hello, world!"

    list_resp = client.get(f"/conversations/{conversation['id']}/messages")
    messages = list_resp.json()
    assert len(messages) == 2
    assert messages[0]["role"] == "user"
    assert messages[1]["role"] == "assistant"
    assert messages[1]["content"] == "Hello, world!"


def test_post_message_includes_conversation_history_for_llm(client, mock_llm_stream):
    _signup(client, email="hank@example.com")
    conversation = _create_conversation(client)

    client.post(f"/conversations/{conversation['id']}/messages", json={"content": "First"})
    client.post(f"/conversations/{conversation['id']}/messages", json={"content": "Second"})

    sent_messages = mock_llm_stream["messages"]
    roles_and_content = [(m["role"], m.get("content")) for m in sent_messages]
    assert roles_and_content[0][0] == "system"
    assert ("user", "First") in roles_and_content
    # last message is the current turn
    assert sent_messages[-1]["role"] == "user"
    assert sent_messages[-1]["content"] == "Second"


def test_messages_require_conversation_ownership(client, mock_llm_stream):
    _signup(client, email="judy@example.com")
    conversation = _create_conversation(client, "Judy's chat")
    client.post("/auth/logout")

    _signup(client, email="mallory@example.com")
    resp = client.post(
        f"/conversations/{conversation['id']}/messages", json={"content": "Sneaky"}
    )
    assert resp.status_code == 404


def test_llm_error_is_reported_and_falls_back_to_stored_message(client, monkeypatch):
    _signup(client, email="karl@example.com")
    conversation = _create_conversation(client)

    async def failing_stream(messages, model=None, on_usage=None):
        raise RuntimeError("gateway exploded")
        yield  # pragma: no cover - makes this an async generator

    monkeypatch.setattr(llm, "stream_chat_completion", failing_stream)

    resp = client.post(
        f"/conversations/{conversation['id']}/messages", json={"content": "Hi"}
    )
    assert resp.status_code == 200
    events = parse_sse(resp.text)
    event_types = [e[0] for e in events]
    assert "error" in event_types
    done_event = next(e for e in events if e[0] == "done")
    assert "error generating a response" in done_event[1]["content"]


def test_chat_rate_limit_returns_429_once_exceeded(client, mock_llm_stream, monkeypatch):
    monkeypatch.setattr(settings, "rate_limit_max_requests", 2)
    _signup(client, email="liu@example.com")
    conversation = _create_conversation(client)

    for _ in range(2):
        resp = client.post(
            f"/conversations/{conversation['id']}/messages", json={"content": "hi"}
        )
        assert resp.status_code == 200

    resp = client.post(f"/conversations/{conversation['id']}/messages", json={"content": "hi"})
    assert resp.status_code == 429


def test_post_message_with_attachment_injects_extracted_text(client, mock_llm_stream):
    _signup(client, email="mona@example.com")
    conversation = _create_conversation(client)

    upload_resp = client.post(
        f"/conversations/{conversation['id']}/files",
        files={"file": ("notes.txt", b"just some notes", "text/plain")},
    )
    file_id = upload_resp.json()["id"]

    resp = client.post(
        f"/conversations/{conversation['id']}/messages",
        json={"content": "What's in the file?", "file_ids": [file_id]},
    )
    assert resp.status_code == 200
    events = parse_sse(resp.text)
    user_event = next(e for e in events if e[0] == "user_message")
    assert len(user_event[1]["attachments"]) == 1
    assert user_event[1]["attachments"][0]["filename"] == "notes.txt"

    sent_messages = mock_llm_stream["messages"]
    assert "notes.txt" in sent_messages[-1]["content"]


def test_post_message_with_unknown_attachment_is_rejected(client, mock_llm_stream):
    _signup(client, email="nate@example.com")
    conversation = _create_conversation(client)

    resp = client.post(
        f"/conversations/{conversation['id']}/messages",
        json={"content": "hi", "file_ids": ["64b7f3c3f3c3f3c3f3c3f3c3"]},
    )
    assert resp.status_code == 404


def test_list_messages_returns_most_recent_n_in_chronological_order(client, monkeypatch):
    """Production-audit follow-up: GET .../messages was previously unbounded. Capping it must
    keep the *most recent* N messages, not the oldest N (which a naive `.limit()` on an
    ascending sort would silently give instead) — otherwise a long conversation gets stuck
    showing only its very beginning forever once it exceeds the cap."""
    import asyncio
    from datetime import datetime, timedelta, timezone

    from app.core.config import settings

    monkeypatch.setattr(settings, "max_messages_returned", 3)

    _signup(client, email="olga@example.com")
    conversation = _create_conversation(client)

    base = datetime.now(timezone.utc)

    async def seed():
        for i in range(5):
            await client.mock_db.messages.insert_one(
                {
                    "conversation_id": conversation["id"],
                    "role": "user",
                    "content": f"message {i}",
                    "attachments": [],
                    "created_at": base + timedelta(seconds=i),
                }
            )

    asyncio.run(seed())

    resp = client.get(f"/conversations/{conversation['id']}/messages")
    assert resp.status_code == 200
    contents = [m["content"] for m in resp.json()]
    # The 3 most recent (2, 3, 4), still in chronological order - not (0, 1, 2).
    assert contents == ["message 2", "message 3", "message 4"]
