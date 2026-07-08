"""Rate limiting backed by Redis (see redis_client.py for the real-vs-fakeredis dev fallback).

Fixed-window counter: INCR a key, set it to expire after the window on the first hit, reject
once the count exceeds the configured max. Two limiters, keyed differently:

- `enforce_chat_rate_limit` — per authenticated user (there's a real user_id to key by).
- `enforce_auth_rate_limit` — per client IP, for signup/login. These are pre-auth: there's no
  user_id yet (that's the whole point — someone hammering login *is* trying to find one), so
  brute-force protection has to be keyed by something else. Without this, nothing stood between
  an attacker and unlimited password guesses against any known email.
"""

from fastapi import Depends, HTTPException, Request, status
from redis.asyncio import Redis

from app.core.config import settings
from app.core.redis_client import get_redis
from app.dependencies import get_current_user
from app.models.user import UserOut


async def _enforce_fixed_window(
    redis: Redis, key: str, max_requests: int, window_seconds: int, message: str
) -> None:
    count = await redis.incr(key)
    if count == 1:
        await redis.expire(key, window_seconds)

    if count > max_requests:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, message)


async def enforce_chat_rate_limit(
    current_user: UserOut = Depends(get_current_user),
    redis: Redis = Depends(get_redis),
) -> None:
    await _enforce_fixed_window(
        redis,
        f"ratelimit:chat:{current_user.id}",
        settings.rate_limit_max_requests,
        settings.rate_limit_window_seconds,
        f"Rate limit exceeded: max {settings.rate_limit_max_requests} messages per "
        f"{settings.rate_limit_window_seconds}s. Try again shortly.",
    )


def _client_ip(request: Request) -> str:
    """The app sits behind an ALB (see docs/ARCHITECTURE.md), which terminates the client's TCP
    connection itself — `request.client.host` would be the ALB's own address, not the real
    client, making every request look like it came from the same IP and defeating this limiter
    entirely (one busy morning of legitimate signups would trip a "global" limit for everyone).
    The ALB always appends the real client IP to `X-Forwarded-For`; take the first entry (there's
    no other untrusted proxy in front of the ALB to have injected a fake one). Falls back to the
    raw transport address for local dev, where there's no proxy at all.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


async def enforce_auth_rate_limit(
    request: Request,
    redis: Redis = Depends(get_redis),
) -> None:
    await _enforce_fixed_window(
        redis,
        f"ratelimit:auth:{_client_ip(request)}",
        settings.auth_rate_limit_max_requests,
        settings.auth_rate_limit_window_seconds,
        f"Too many attempts: max {settings.auth_rate_limit_max_requests} per "
        f"{settings.auth_rate_limit_window_seconds}s. Try again shortly.",
    )
