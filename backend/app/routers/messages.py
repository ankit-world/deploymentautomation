import base64
import json
import logging
import time
from datetime import datetime, timezone
from typing import Any

from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.encoders import jsonable_encoder
from fastapi.responses import StreamingResponse
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.core import metrics
from app.core.config import settings
from app.core.db import get_db
from app.core.rate_limit import enforce_chat_rate_limit
from app.core.serialization import serialize_doc
from app.dependencies import get_current_user
from app.models.message import MessageCreate, MessageOut
from app.models.user import UserOut
from app.routers.conversations import get_owned_conversation
from app.services import llm
from app.services.storage import StorageBackend, get_storage

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/conversations/{conversation_id}/messages", tags=["messages"])

# Fallback assistant content if the LLM call fails outright (before any tokens streamed), so the
# conversation still has something coherent stored rather than an empty message.
LLM_ERROR_FALLBACK = "Sorry, I ran into an error generating a response. Please try again."


def _sse_event(event: str, data: Any) -> str:
    return f"event: {event}\ndata: {json.dumps(jsonable_encoder(data))}\n\n"


def _attachment_summary(file_doc: dict) -> dict:
    return {
        "id": str(file_doc["_id"]),
        "filename": file_doc["filename"],
        "mimetype": file_doc["mimetype"],
        "kind": file_doc["kind"],
        "size": file_doc["size"],
    }


@router.post("")
async def create_message(
    conversation_id: str,
    body: MessageCreate,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
    storage: StorageBackend = Depends(get_storage),
    _rate_limit: None = Depends(enforce_chat_rate_limit),
) -> StreamingResponse:
    """Posts a user message (with optional file attachments) and streams the assistant's reply
    back as Server-Sent Events:

    - `event: user_message` — the persisted user message (fired immediately, so the client has
      its id before the reply starts arriving).
    - `event: token` — repeated, `{"content": "<delta text>"}` chunks as the LLM generates them.
    - `event: error` — only if the LLM call fails; `{"detail": "..."}`.
    - `event: done` — the persisted assistant message, once streaming finishes.
    """
    await get_owned_conversation(conversation_id, current_user.id, db)

    file_docs: list[dict] = []
    if body.file_ids:
        object_ids = [ObjectId(fid) for fid in body.file_ids if ObjectId.is_valid(fid)]
        if len(object_ids) != len(body.file_ids):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Attached file not found")
        cursor = db.files.find(
            {
                "_id": {"$in": object_ids},
                "conversation_id": conversation_id,
                "user_id": current_user.id,
            }
        )
        file_docs = [doc async for doc in cursor]
        if len(file_docs) != len(body.file_ids):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Attached file not found")

    # Prior turns, oldest first, for multi-turn context.
    history = [
        {"role": doc["role"], "content": doc["content"]}
        async for doc in db.messages.find({"conversation_id": conversation_id}).sort(
            "created_at", 1
        )
    ]

    now = datetime.now(timezone.utc)
    user_doc = {
        "conversation_id": conversation_id,
        "role": "user",
        "content": body.content,
        "attachments": [_attachment_summary(fd) for fd in file_docs],
        "created_at": now,
    }
    user_result = await db.messages.insert_one(user_doc)
    user_doc["_id"] = user_result.inserted_id
    # `serialize_doc` already carries `attachments` as a list of plain dicts; pydantic coerces
    # them into FileAttachmentSummary automatically when constructing MessageOut.
    user_message = MessageOut(**serialize_doc(user_doc))

    # Attachments for the LLM: images need their bytes (base64), docs need their extracted text.
    llm_attachments = []
    for fd in file_docs:
        item: dict = {"kind": fd["kind"], "filename": fd["filename"], "mimetype": fd["mimetype"]}
        if fd["kind"] == "image":
            data = await storage.load(fd["storage_key"])
            item["data_b64"] = base64.b64encode(data).decode("ascii")
        else:
            item["extracted_text"] = fd.get("extracted_text")
        llm_attachments.append(item)

    llm_messages = (
        [{"role": "system", "content": llm.SYSTEM_PROMPT}]
        + history
        + [llm.build_user_message(body.content, llm_attachments)]
    )

    async def event_stream():
        yield _sse_event("user_message", user_message)
        await metrics.record_chat_message()
        logger.info(
            "chat message sent",
            extra={
                "event": "message_sent",
                "user_id": current_user.id,
                "conversation_id": conversation_id,
                "message_id": str(user_doc["_id"]),
                "attachment_count": len(file_docs),
            },
        )

        model = settings.openai_model
        usage: dict = {}
        collected = ""
        llm_start = time.perf_counter()
        try:
            async for delta in llm.stream_chat_completion(
                llm_messages, on_usage=usage.update
            ):
                collected += delta
                yield _sse_event("token", {"content": delta})
            await metrics.record_llm_call(
                model,
                (time.perf_counter() - llm_start) * 1000,
                success=True,
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
                total_tokens=usage.get("total_tokens"),
            )
        except Exception as exc:
            logger.exception(
                "LLM call failed for conversation %s",
                conversation_id,
                extra={
                    "event": "llm_call_failed",
                    "user_id": current_user.id,
                    "conversation_id": conversation_id,
                    "model": model,
                },
            )
            collected = collected or LLM_ERROR_FALLBACK
            await metrics.record_llm_call(
                model, (time.perf_counter() - llm_start) * 1000, success=False
            )
            yield _sse_event("error", {"detail": str(exc)})

        assistant_doc = {
            "conversation_id": conversation_id,
            "role": "assistant",
            "content": collected,
            "attachments": [],
            "created_at": datetime.now(timezone.utc),
        }
        assistant_result = await db.messages.insert_one(assistant_doc)
        assistant_doc["_id"] = assistant_result.inserted_id

        await db.conversations.update_one(
            {"_id": ObjectId(conversation_id)},
            {"$set": {"updated_at": datetime.now(timezone.utc)}},
        )

        assistant_message = MessageOut(**serialize_doc(assistant_doc))
        yield _sse_event("done", assistant_message)

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@router.get("", response_model=list[MessageOut])
async def list_messages(
    conversation_id: str,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
) -> list[MessageOut]:
    await get_owned_conversation(conversation_id, current_user.id, db)

    cursor = db.messages.find({"conversation_id": conversation_id}).sort("created_at", 1)
    return [MessageOut(**serialize_doc(doc)) async for doc in cursor]
