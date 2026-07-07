def _signup(client, email="wendy@example.com"):
    resp = client.post(
        "/auth/signup", json={"email": email, "password": "hunter22", "name": "Wendy"}
    )
    assert resp.status_code == 201
    return resp.json()


def _create_conversation(client, title="Files chat"):
    resp = client.post("/conversations", json={"title": title})
    assert resp.status_code == 201
    return resp.json()


def test_upload_and_download_roundtrip_bytes_unmodified(client):
    _signup(client)
    conversation = _create_conversation(client)

    original_bytes = b"the quick brown fox jumps over the lazy dog \x00\x01\x02"
    upload_resp = client.post(
        f"/conversations/{conversation['id']}/files",
        files={"file": ("notes.txt", original_bytes, "text/plain")},
    )
    assert upload_resp.status_code == 201
    file_meta = upload_resp.json()
    assert file_meta["filename"] == "notes.txt"
    assert file_meta["kind"] == "other"
    assert file_meta["size"] == len(original_bytes)

    download_resp = client.get(
        f"/conversations/{conversation['id']}/files/{file_meta['id']}/download"
    )
    assert download_resp.status_code == 200
    assert download_resp.content == original_bytes


def test_upload_pdf_extracts_text_preview(client):
    _signup(client, email="xena@example.com")
    conversation = _create_conversation(client)

    from tests.test_extract import make_pdf_bytes

    pdf_bytes = make_pdf_bytes("Findable marker TEST999")
    resp = client.post(
        f"/conversations/{conversation['id']}/files",
        files={"file": ("doc.pdf", pdf_bytes, "application/pdf")},
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["kind"] == "pdf"
    assert "TEST999" in (body["extracted_text_preview"] or "")


def test_upload_rejects_empty_file(client):
    _signup(client, email="yusuf@example.com")
    conversation = _create_conversation(client)

    resp = client.post(
        f"/conversations/{conversation['id']}/files",
        files={"file": ("empty.txt", b"", "text/plain")},
    )
    assert resp.status_code == 400


def test_upload_requires_conversation_ownership(client):
    _signup(client, email="zack@example.com")
    conversation = _create_conversation(client)
    client.post("/auth/logout")

    _signup(client, email="amy2@example.com")
    resp = client.post(
        f"/conversations/{conversation['id']}/files",
        files={"file": ("sneaky.txt", b"data", "text/plain")},
    )
    assert resp.status_code == 404


def test_download_requires_ownership(client):
    _signup(client, email="ben2@example.com")
    conversation = _create_conversation(client)
    upload_resp = client.post(
        f"/conversations/{conversation['id']}/files",
        files={"file": ("secret.txt", b"top secret", "text/plain")},
    )
    file_id = upload_resp.json()["id"]
    client.post("/auth/logout")

    _signup(client, email="cara2@example.com")
    resp = client.get(f"/conversations/{conversation['id']}/files/{file_id}/download")
    assert resp.status_code == 404
