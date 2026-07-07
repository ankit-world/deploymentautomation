def _signup(client, email="frank@example.com"):
    resp = client.post(
        "/auth/signup", json={"email": email, "password": "hunter22", "name": "Frank"}
    )
    assert resp.status_code == 201
    return resp.json()


def test_create_list_rename_delete_conversation(client):
    _signup(client)

    create_resp = client.post("/conversations", json={"title": "First chat"})
    assert create_resp.status_code == 201
    conversation = create_resp.json()
    assert conversation["title"] == "First chat"

    list_resp = client.get("/conversations")
    assert list_resp.status_code == 200
    assert len(list_resp.json()) == 1

    rename_resp = client.patch(
        f"/conversations/{conversation['id']}", json={"title": "Renamed chat"}
    )
    assert rename_resp.status_code == 200
    assert rename_resp.json()["title"] == "Renamed chat"

    delete_resp = client.delete(f"/conversations/{conversation['id']}")
    assert delete_resp.status_code == 204
    assert client.get("/conversations").json() == []


def test_conversations_are_scoped_to_owner(client):
    _signup(client, email="grace@example.com")
    conversation = client.post("/conversations", json={"title": "Grace's chat"}).json()
    client.post("/auth/logout")

    _signup(client, email="heidi@example.com")
    rename_resp = client.patch(
        f"/conversations/{conversation['id']}", json={"title": "Hijacked"}
    )
    assert rename_resp.status_code == 404


def test_post_message_creates_user_and_placeholder_assistant_reply(client):
    _signup(client, email="ivan@example.com")
    conversation = client.post("/conversations", json={"title": "Chat"}).json()

    resp = client.post(
        f"/conversations/{conversation['id']}/messages", json={"content": "Hello there"}
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["user_message"]["content"] == "Hello there"
    assert body["user_message"]["role"] == "user"
    assert body["assistant_message"]["role"] == "assistant"

    list_resp = client.get(f"/conversations/{conversation['id']}/messages")
    assert list_resp.status_code == 200
    messages = list_resp.json()
    assert len(messages) == 2
    assert messages[0]["role"] == "user"
    assert messages[1]["role"] == "assistant"


def test_messages_require_conversation_ownership(client):
    _signup(client, email="judy@example.com")
    conversation = client.post("/conversations", json={"title": "Judy's chat"}).json()
    client.post("/auth/logout")

    _signup(client, email="mallory@example.com")
    resp = client.post(
        f"/conversations/{conversation['id']}/messages", json={"content": "Sneaky"}
    )
    assert resp.status_code == 404
