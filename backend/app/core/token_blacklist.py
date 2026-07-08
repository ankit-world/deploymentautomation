"""Redis-backed refresh-token blacklist.

Session 09 correction: `docs/ARCHITECTURE.md`'s "Redis" section describes refresh tokens as
"tracked in Redis so logout / revocation actually works", but until this session `POST
/auth/logout` only cleared cookies — the refresh token itself remained cryptographically valid
until it naturally expired (see the removed comment in `app/routers/auth.py`). This module makes
that description true: logout now records the token in Redis so `POST /auth/refresh` can reject
it even if the cookie (or a copy of it) is replayed afterward.

Keyed by a SHA-256 hash of the token, not the raw token, so a Redis dump/`SCAN` doesn't expose a
usable credential. Entry TTL matches the token's own remaining lifetime (`token_ttl_seconds`) —
once the token would have expired anyway, the blacklist entry is pointless and Redis reclaims it
for free.
"""

import hashlib

from redis.asyncio import Redis

from app.core.security import token_ttl_seconds

_PREFIX = "blacklist:refresh:"


def _key(token: str) -> str:
    return _PREFIX + hashlib.sha256(token.encode("utf-8")).hexdigest()


async def blacklist_refresh_token(redis: Redis, token: str) -> None:
    """Record `token` as revoked until its own expiry. No-op if it's already invalid/expired —
    nothing to protect against replaying a token that wouldn't decode anyway."""
    ttl = token_ttl_seconds(token)
    if ttl is not None:
        await redis.set(_key(token), "1", ex=ttl)


async def is_refresh_token_blacklisted(redis: Redis, token: str) -> bool:
    return bool(await redis.exists(_key(token)))
