def test_signup_login_me_flow(client):
    signup_resp = client.post(
        "/auth/signup",
        json={"email": "Alice@Example.com", "password": "hunter22", "name": "Alice"},
    )
    assert signup_resp.status_code == 201
    body = signup_resp.json()
    assert body["email"] == "alice@example.com"
    assert body["name"] == "Alice"
    assert "access_token" in client.cookies

    me_resp = client.get("/auth/me")
    assert me_resp.status_code == 200
    assert me_resp.json()["email"] == "alice@example.com"


def test_signup_duplicate_email_rejected(client):
    payload = {"email": "bob@example.com", "password": "hunter22", "name": "Bob"}
    assert client.post("/auth/signup", json=payload).status_code == 201
    assert client.post("/auth/signup", json=payload).status_code == 409


def test_login_wrong_password_rejected(client):
    client.post(
        "/auth/signup",
        json={"email": "carol@example.com", "password": "correct-horse", "name": "Carol"},
    )
    client.cookies.clear()

    resp = client.post(
        "/auth/login", json={"email": "carol@example.com", "password": "wrong-password"}
    )
    assert resp.status_code == 401


def test_me_requires_authentication(client):
    resp = client.get("/auth/me")
    assert resp.status_code == 401


def test_logout_clears_cookies_and_revokes_access(client):
    client.post(
        "/auth/signup",
        json={"email": "dave@example.com", "password": "hunter22", "name": "Dave"},
    )
    assert client.get("/auth/me").status_code == 200

    logout_resp = client.post("/auth/logout")
    assert logout_resp.status_code == 204
    assert client.get("/auth/me").status_code == 401


def test_refresh_issues_new_access_token(client):
    client.post(
        "/auth/signup",
        json={"email": "erin@example.com", "password": "hunter22", "name": "Erin"},
    )
    refresh_resp = client.post("/auth/refresh")
    assert refresh_resp.status_code == 204
    assert client.get("/auth/me").status_code == 200
