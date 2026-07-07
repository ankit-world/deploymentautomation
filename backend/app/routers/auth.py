from datetime import datetime, timezone

from fastapi import APIRouter, Cookie, Depends, HTTPException, Response, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.core.config import settings
from app.core.db import get_db
from app.core.security import (
    REFRESH_TOKEN_TYPE,
    InvalidTokenError,
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    verify_password,
)
from app.core.serialization import serialize_doc
from app.dependencies import get_current_user
from app.models.user import UserLogin, UserOut, UserSignup

router = APIRouter(prefix="/auth", tags=["auth"])

ACCESS_COOKIE_MAX_AGE = settings.access_token_expire_minutes * 60
REFRESH_COOKIE_MAX_AGE = settings.refresh_token_expire_days * 24 * 60 * 60


def _set_auth_cookies(response: Response, user_id: str) -> None:
    access_token = create_access_token(user_id)
    refresh_token = create_refresh_token(user_id)

    # secure=False for local HTTP dev; flip to True once served over HTTPS (session 12).
    response.set_cookie(
        "access_token",
        access_token,
        max_age=ACCESS_COOKIE_MAX_AGE,
        httponly=True,
        samesite="lax",
        secure=False,
    )
    response.set_cookie(
        "refresh_token",
        refresh_token,
        max_age=REFRESH_COOKIE_MAX_AGE,
        httponly=True,
        samesite="lax",
        secure=False,
        path="/auth",
    )


@router.post("/signup", response_model=UserOut, status_code=status.HTTP_201_CREATED)
async def signup(
    body: UserSignup, response: Response, db: AsyncIOMotorDatabase = Depends(get_db)
) -> UserOut:
    existing = await db.users.find_one({"email": body.email.lower()})
    if existing is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")

    now = datetime.now(timezone.utc)
    doc = {
        "email": body.email.lower(),
        "name": body.name,
        "hashed_password": hash_password(body.password),
        "created_at": now,
    }
    result = await db.users.insert_one(doc)
    doc["_id"] = result.inserted_id

    _set_auth_cookies(response, str(result.inserted_id))
    return UserOut(**serialize_doc(doc))


@router.post("/login", response_model=UserOut)
async def login(
    body: UserLogin, response: Response, db: AsyncIOMotorDatabase = Depends(get_db)
) -> UserOut:
    doc = await db.users.find_one({"email": body.email.lower()})
    if doc is None or not verify_password(body.password, doc["hashed_password"]):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect email or password")

    _set_auth_cookies(response, str(doc["_id"]))
    return UserOut(**serialize_doc(doc))


@router.post("/refresh", status_code=status.HTTP_204_NO_CONTENT)
async def refresh(
    response: Response, refresh_token: str | None = Cookie(default=None)
) -> None:
    if refresh_token is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated")

    try:
        user_id = decode_token(refresh_token, REFRESH_TOKEN_TYPE)
    except InvalidTokenError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token") from exc

    new_access_token = create_access_token(user_id)
    response.set_cookie(
        "access_token",
        new_access_token,
        max_age=ACCESS_COOKIE_MAX_AGE,
        httponly=True,
        samesite="lax",
        secure=False,
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(response: Response) -> None:
    # Cookie-clear-only logout. Tokens remain cryptographically valid until they expire on
    # their own (short-lived access token) — real server-side revocation via a Redis
    # blacklist lands once Redis is wired up in a later session (see docs/ARCHITECTURE.md).
    response.delete_cookie("access_token")
    response.delete_cookie("refresh_token", path="/auth")


@router.get("/me", response_model=UserOut)
async def me(current_user: UserOut = Depends(get_current_user)) -> UserOut:
    return current_user
