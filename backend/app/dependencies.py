from bson import ObjectId
from fastapi import Cookie, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.core.db import get_db
from app.core.security import ACCESS_TOKEN_TYPE, InvalidTokenError, decode_token
from app.core.serialization import serialize_doc
from app.models.user import UserOut


async def get_current_user(
    access_token: str | None = Cookie(default=None),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> UserOut:
    if access_token is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated")

    try:
        user_id = decode_token(access_token, ACCESS_TOKEN_TYPE)
    except InvalidTokenError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token") from exc

    if not ObjectId.is_valid(user_id):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token subject")

    user_doc = await db.users.find_one({"_id": ObjectId(user_id)})
    if user_doc is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User no longer exists")

    return UserOut(**serialize_doc(user_doc))
