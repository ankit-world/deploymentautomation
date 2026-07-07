from datetime import datetime, timezone

from bson import ObjectId
from fastapi import APIRouter, Depends, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.core.db import get_db
from app.core.serialization import serialize_doc
from app.dependencies import get_current_user
from app.models.message import MessageCreate, MessageOut, MessagePairOut
from app.models.user import UserOut
from app.routers.conversations import get_owned_conversation

router = APIRouter(prefix="/conversations/{conversation_id}/messages", tags=["messages"])

PLACEHOLDER_ASSISTANT_REPLY = (
    "This is a placeholder response — real LLM streaming replies land in session 02 "
    "(see docs/sessions/02-backend-llm-files.md)."
)


@router.post("", response_model=MessagePairOut, status_code=status.HTTP_201_CREATED)
async def create_message(
    conversation_id: str,
    body: MessageCreate,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> MessagePairOut:
    await get_owned_conversation(conversation_id, current_user.id, db)

    now = datetime.now(timezone.utc)
    user_doc = {
        "conversation_id": conversation_id,
        "role": "user",
        "content": body.content,
        "created_at": now,
    }
    user_result = await db.messages.insert_one(user_doc)
    user_doc["_id"] = user_result.inserted_id

    assistant_doc = {
        "conversation_id": conversation_id,
        "role": "assistant",
        "content": PLACEHOLDER_ASSISTANT_REPLY,
        "created_at": datetime.now(timezone.utc),
    }
    assistant_result = await db.messages.insert_one(assistant_doc)
    assistant_doc["_id"] = assistant_result.inserted_id

    await db.conversations.update_one(
        {"_id": ObjectId(conversation_id)},
        {"$set": {"updated_at": datetime.now(timezone.utc)}},
    )

    return MessagePairOut(
        user_message=MessageOut(**serialize_doc(user_doc)),
        assistant_message=MessageOut(**serialize_doc(assistant_doc)),
    )


@router.get("", response_model=list[MessageOut])
async def list_messages(
    conversation_id: str,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> list[MessageOut]:
    await get_owned_conversation(conversation_id, current_user.id, db)

    cursor = db.messages.find({"conversation_id": conversation_id}).sort("created_at", 1)
    return [MessageOut(**serialize_doc(doc)) async for doc in cursor]
