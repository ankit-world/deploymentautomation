from app.core.config import settings
from app.services.llm import build_user_message


def test_build_user_message_text_only():
    msg = build_user_message("Hello there", [])
    assert msg == {"role": "user", "content": "Hello there"}


def test_build_user_message_injects_document_text():
    attachments = [
        {"kind": "pdf", "filename": "report.pdf", "extracted_text": "Q3 revenue was $5M."}
    ]
    msg = build_user_message("Summarize this", attachments)
    assert msg["role"] == "user"
    assert isinstance(msg["content"], str)
    assert "Summarize this" in msg["content"]
    assert "report.pdf" in msg["content"]
    assert "Q3 revenue was $5M." in msg["content"]


def test_build_user_message_notes_missing_extraction():
    attachments = [{"kind": "docx", "filename": "empty.docx", "extracted_text": None}]
    msg = build_user_message("What's in this?", attachments)
    assert "empty.docx" in msg["content"]
    assert "no text could be extracted" in msg["content"]


def test_build_user_message_with_image_produces_vision_content_parts(monkeypatch):
    monkeypatch.setattr(settings, "vision_supported", True)
    attachments = [
        {"kind": "image", "filename": "cat.png", "mimetype": "image/png", "data_b64": "AAAA"}
    ]
    msg = build_user_message("What is this?", attachments)
    assert msg["role"] == "user"
    assert isinstance(msg["content"], list)
    text_part = next(p for p in msg["content"] if p["type"] == "text")
    image_part = next(p for p in msg["content"] if p["type"] == "image_url")
    assert "What is this?" in text_part["text"]
    assert image_part["image_url"]["url"] == "data:image/png;base64,AAAA"


def test_build_user_message_degrades_gracefully_when_vision_unsupported(monkeypatch):
    monkeypatch.setattr(settings, "vision_supported", False)
    attachments = [
        {"kind": "image", "filename": "cat.png", "mimetype": "image/png", "data_b64": "AAAA"}
    ]
    msg = build_user_message("What is this?", attachments)
    assert isinstance(msg["content"], str)
    assert "cat.png" in msg["content"]
    assert "does not support image inputs" in msg["content"]
