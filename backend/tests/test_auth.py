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


def test_signup_race_condition_caught_by_unique_index(client, monkeypatch):
    """The pre-check (find_one) only catches the common sequential case — two truly concurrent
    signups for the same email can both pass it before either has inserted. Simulate that race
    directly: insert the conflicting user "behind the API's back" (as a concurrent request would
    have), then force find_one to report "no conflict" (as it legitimately would have, at the
    instant both requests checked). The unique index must be what actually rejects the second
    insert — proving app/routers/auth.py's except DuplicateKeyError path, not just the pre-check,
    is what makes this safe."""
    import asyncio

    asyncio.run(
        client.mock_db.users.insert_one(
            {
                "email": "race@example.com",
                "name": "Already Here",
                "hashed_password": "irrelevant",
                "created_at": "2026-01-01T00:00:00Z",
            }
        )
    )

    async def find_one_sees_no_conflict(*args, **kwargs):
        return None

    monkeypatch.setattr(client.mock_db.users, "find_one", find_one_sees_no_conflict)

    resp = client.post(
        "/auth/signup",
        json={"email": "race@example.com", "password": "hunter22", "name": "Racer"},
    )
    assert resp.status_code == 409


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


def test_login_is_rate_limited_per_ip(client):
    """Before this, only the chat endpoint was rate-limited - nothing stood between an attacker
    and unlimited password guesses against a known email. Login intentionally fails every
    attempt here (wrong password) so this only exercises the rate limiter, not the auth
    outcome."""
    from app.core.config import settings

    payload = {"email": "nobody@example.com", "password": "wrong-password"}
    for _ in range(settings.auth_rate_limit_max_requests):
        resp = client.post("/auth/login", json=payload)
        assert resp.status_code == 401  # wrong password, but not yet rate-limited

    resp = client.post("/auth/login", json=payload)
    assert resp.status_code == 429


def test_signup_is_rate_limited_per_ip(client):
    from app.core.config import settings

    for i in range(settings.auth_rate_limit_max_requests):
        resp = client.post(
            "/auth/signup",
            json={"email": f"ratelimit{i}@example.com", "password": "hunter22", "name": "X"},
        )
        assert resp.status_code == 201
        client.cookies.clear()  # each signup logs the client in; don't let that affect the next

    resp = client.post(
        "/auth/signup",
        json={"email": "one-too-many@example.com", "password": "hunter22", "name": "X"},
    )
    assert resp.status_code == 429
