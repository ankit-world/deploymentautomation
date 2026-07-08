def test_unhandled_exception_returns_clean_500_json(client, monkeypatch):
    """Before the global exception handler existed, an unhandled exception in a route would
    leak Starlette's bare default error response, inconsistent with every other error in this
    app being `{"detail": "..."}`, and would never be logged through the structured pipeline."""
    from app.core.serialization import serialize_doc

    def boom(doc):
        raise RuntimeError("simulated unexpected failure")

    monkeypatch.setattr("app.routers.conversations.serialize_doc", boom)

    client.post(
        "/auth/signup",
        json={"email": "crash-test@example.com", "password": "hunter22", "name": "Crash"},
    )
    resp = client.post("/conversations", json={"title": "Should 500 cleanly"})

    assert resp.status_code == 500
    assert resp.json() == {"detail": "Internal server error"}


def test_unhandled_exception_is_logged(client, monkeypatch, caplog):
    import logging

    def boom(doc):
        raise RuntimeError("simulated unexpected failure")

    monkeypatch.setattr("app.routers.conversations.serialize_doc", boom)

    client.post(
        "/auth/signup",
        json={"email": "crash-log-test@example.com", "password": "hunter22", "name": "Crash"},
    )
    caplog.clear()
    with caplog.at_level(logging.ERROR):
        client.post("/conversations", json={"title": "Should be logged"})

    records = [r for r in caplog.records if getattr(r, "event", None) == "unhandled_exception"]
    assert len(records) == 1
    assert records[0].path == "/conversations"
    assert "simulated unexpected failure" in caplog.text
