import logging

from app.core.logging_config import JsonFormatter


def _request_log_records(caplog):
    return [r for r in caplog.records if getattr(r, "event", None) == "request"]


def test_request_completion_is_logged_with_structured_fields(client, caplog):
    with caplog.at_level(logging.INFO):
        resp = client.get("/conversations")
    assert resp.status_code == 401

    records = _request_log_records(caplog)
    assert len(records) == 1
    record = records[0]
    assert record.method == "GET"
    assert record.route == "/conversations"
    assert record.status_code == 401
    assert record.user_id is None
    assert isinstance(record.duration_ms, float)


def test_health_endpoint_is_not_logged(client, caplog):
    with caplog.at_level(logging.INFO):
        resp = client.get("/health")
    assert resp.status_code == 200

    assert _request_log_records(caplog) == []


def test_authenticated_request_log_includes_user_id(client, caplog):
    signup = client.post(
        "/auth/signup",
        json={"email": "log-test@example.com", "password": "hunter22", "name": "Log Test"},
    )
    assert signup.status_code == 201
    user_id = signup.json()["id"]

    caplog.clear()  # caplog accumulates across the whole test, not just inside `with` blocks
    with caplog.at_level(logging.INFO):
        resp = client.get("/auth/me")
    assert resp.status_code == 200

    records = _request_log_records(caplog)
    assert len(records) == 1
    assert records[0].user_id == user_id


def test_json_formatter_produces_valid_parseable_json():
    import json

    formatter = JsonFormatter()
    record = logging.LogRecord(
        name="app.test",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="something happened",
        args=(),
        exc_info=None,
    )
    record.custom_field = "custom_value"

    parsed = json.loads(formatter.format(record))
    assert parsed["message"] == "something happened"
    assert parsed["logger"] == "app.test"
    assert parsed["level"] == "INFO"
    assert parsed["custom_field"] == "custom_value"
    assert "timestamp" in parsed


def test_json_formatter_includes_exception_info():
    import json

    formatter = JsonFormatter()
    try:
        raise ValueError("boom")
    except ValueError:
        import sys

        record = logging.LogRecord(
            name="app.test",
            level=logging.ERROR,
            pathname=__file__,
            lineno=1,
            msg="failed",
            args=(),
            exc_info=sys.exc_info(),
        )
    parsed = json.loads(formatter.format(record))
    assert "ValueError: boom" in parsed["exception"]
