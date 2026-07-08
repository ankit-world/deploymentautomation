import logging
from datetime import datetime, timezone

from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.core.db import get_db
from app.core.serialization import serialize_doc
from app.dependencies import get_current_user
from app.models.conversation import ConversationCreate, ConversationOut, ConversationRename
from app.models.user import UserOut

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/conversations", tags=["conversations"])


async def get_owned_conversation(
    conversation_id: str, user_id: str, db: AsyncIOMotorDatabase
) -> dict:
    if not ObjectId.is_valid(conversation_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Conversation not found")

    doc = await db.conversations.find_one(
        {"_id": ObjectId(conversation_id), "user_id": user_id}
    )
    if doc is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Conversation not found")
    return doc


@router.post("", response_model=ConversationOut, status_code=status.HTTP_201_CREATED)
async def create_conversation(
    body: ConversationCreate,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> ConversationOut:
    now = datetime.now(timezone.utc)
    doc = {
        "user_id": current_user.id,
        "title": body.title,
        "created_at": now,
        "updated_at": now,
    }
    result = await db.conversations.insert_one(doc)
    doc["_id"] = result.inserted_id
    logger.info(
        "conversation created",
        extra={
            "event": "conversation_created",
            "user_id": current_user.id,
            "conversation_id": str(result.inserted_id),
        },
    )
    return ConversationOut(**serialize_doc(doc))


@router.get("", response_model=list[ConversationOut])
async def list_conversations(
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> list[ConversationOut]:
    cursor = db.conversations.find({"user_id": current_user.id}).sort("updated_at", -1)
    return [ConversationOut(**serialize_doc(doc)) async for doc in cursor]


@router.patch("/{conversation_id}", response_model=ConversationOut)
async def rename_conversation(
    conversation_id: str,
    body: ConversationRename,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> ConversationOut:
    await get_owned_conversation(conversation_id, current_user.id, db)

    await db.conversations.update_one(
        {"_id": ObjectId(conversation_id)},
        {"$set": {"title": body.title, "updated_at": datetime.now(timezone.utc)}},
    )
    doc = await db.conversations.find_one({"_id": ObjectId(conversation_id)})
    return ConversationOut(**serialize_doc(doc))


@router.delete("/{conversation_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_conversation(
    conversation_id: str,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> None:
    await get_owned_conversation(conversation_id, current_user.id, db)

    await db.conversations.delete_one({"_id": ObjectId(conversation_id)})
    await db.messages.delete_many({"conversation_id": conversation_id})
    logger.info(
        "conversation deleted",
        extra={
            "event": "conversation_deleted",
            "user_id": current_user.id,
            "conversation_id": conversation_id,
        },
    )
