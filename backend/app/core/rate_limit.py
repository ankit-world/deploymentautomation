"""Per-user rate limiting for the chat endpoint, backed by Redis (see redis_client.py for the
real-vs-fakeredis dev fallback).

Fixed-window counter: INCR a key namespaced by user id, set it to expire after the window on
the first hit, reject once the count exceeds the configured max.
"""

from fastapi import Depends, HTTPException, status
from redis.asyncio import Redis

from app.core.config import settings
from app.core.redis_client import get_redis
from app.dependencies import get_current_user
from app.models.user import UserOut


async def enforce_chat_rate_limit(
    current_user: UserOut = Depends(get_current_user),
    redis: Redis = Depends(get_redis),
) -> None:
    key = f"ratelimit:chat:{current_user.id}"
    count = await redis.incr(key)
    if count == 1:
        await redis.expire(key, settings.rate_limit_window_seconds)

    if count > settings.rate_limit_max_requests:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"Rate limit exceeded: max {settings.rate_limit_max_requests} messages per "
            f"{settings.rate_limit_window_seconds}s. Try again shortly.",
        )
