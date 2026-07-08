import json

from app.core import metrics


def _parse_emf_lines(raw: str) -> list[dict]:
    """EMF's stdout sink writes one JSON object per line. capsys captures request-log noise
    (uvicorn access lines, etc.) alongside it, so only lines that actually parse as our metrics
    namespace count."""
    lines = []
    for line in raw.strip().splitlines():
        try:
            obj = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if obj.get("_aws", {}).get("CloudWatchMetrics", [{}])[0].get("Namespace") == metrics.NAMESPACE:
            lines.append(obj)
    return lines


def test_request_metric_emitted_for_a_real_request(client, capsys):
    resp = client.get("/conversations")
    assert resp.status_code == 401  # unauthenticated, but that's fine - still a real request

    emitted = _parse_emf_lines(capsys.readouterr().out)
    request_metrics = [e for e in emitted if "RequestCount" in e]
    assert len(request_metrics) == 1
    metric = request_metrics[0]
    assert metric["RequestCount"] == 1
    assert metric["Route"] == "/conversations"
    assert metric["Method"] == "GET"
    assert metric["StatusCode"] == 401
    assert metric["ClientErrorCount"] == 1
    assert "ServerErrorCount" not in metric


def test_health_endpoint_does_not_emit_a_metric(client, capsys):
    resp = client.get("/health")
    assert resp.status_code == 200

    emitted = _parse_emf_lines(capsys.readouterr().out)
    assert emitted == []


def test_chat_message_and_llm_metrics_emitted_on_a_real_chat_turn(client, mock_llm_stream, capsys):
    signup = client.post(
        "/auth/signup", json={"email": "metrics-test@example.com", "password": "hunter22", "name": "M"}
    )
    assert signup.status_code == 201
    conversation = client.post("/conversations", json={"title": "Metrics test"}).json()

    resp = client.post(
        f"/conversations/{conversation['id']}/messages", json={"content": "Hello there"}
    )
    assert resp.status_code == 200

    emitted = _parse_emf_lines(capsys.readouterr().out)
    chat_metrics = [e for e in emitted if "ChatMessagesSent" in e]
    llm_metrics = [e for e in emitted if "LlmCallCount" in e]

    assert len(chat_metrics) == 1

    assert len(llm_metrics) == 1
    llm_metric = llm_metrics[0]
    assert llm_metric["Success"] == "true"
    assert llm_metric["LlmCallCount"] == 1
    assert llm_metric["LlmPromptTokens"] == 12
    assert llm_metric["LlmCompletionTokens"] == 4
    assert llm_metric["LlmTotalTokens"] == 16


def test_file_upload_metric_emitted(client, capsys):
    client.post(
        "/auth/signup", json={"email": "metrics-upload@example.com", "password": "hunter22", "name": "M"}
    )
    conversation = client.post("/conversations", json={"title": "Upload test"}).json()

    resp = client.post(
        f"/conversations/{conversation['id']}/files",
        files={"file": ("note.txt", b"hello metrics", "text/plain")},
    )
    assert resp.status_code == 201

    emitted = _parse_emf_lines(capsys.readouterr().out)
    upload_metrics = [e for e in emitted if "FileUploadCount" in e]
    assert len(upload_metrics) == 1
    metric = upload_metrics[0]
    assert metric["FileUploadCount"] == 1
    assert metric["FileUploadSize"] == len(b"hello metrics")
    assert metric["Kind"] == "other"
