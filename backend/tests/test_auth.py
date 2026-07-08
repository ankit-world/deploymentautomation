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


def test_logout_blacklists_refresh_token(client):
    """Session 09: logout must actually revoke the refresh token via the Redis blacklist, not
    just clear cookies — a copy of the old refresh token replayed after logout must be rejected
    by POST /auth/refresh. This is the exact check re-run live against ElastiCache in prod."""
    client.post(
        "/auth/signup",
        json={"email": "frank@example.com", "password": "hunter22", "name": "Frank"},
    )
    old_refresh_token = client.cookies["refresh_token"]

    assert client.post("/auth/logout").status_code == 204

    # Replay the pre-logout refresh token directly (bypassing the now-cleared cookie jar) —
    # this is the scenario a bare-JWT-only logout can't defend against.
    replay_resp = client.post("/auth/refresh", cookies={"refresh_token": old_refresh_token})
    assert replay_resp.status_code == 401
