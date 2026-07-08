import mimetypes
import uuid
from datetime import datetime, timezone

from bson import ObjectId
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from fastapi.responses import RedirectResponse, StreamingResponse
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.core import metrics
from app.core.config import settings
from app.core.db import get_db
from app.core.serialization import serialize_doc
from app.dependencies import get_current_user
from app.models.file import FileOut
from app.models.user import UserOut
from app.routers.conversations import get_owned_conversation
from app.services.extract import classify_kind, extract_text
from app.services.storage import StorageBackend, get_storage

router = APIRouter(prefix="/conversations/{conversation_id}/files", tags=["files"])

PREVIEW_CHARS = 500


async def get_owned_file(
    conversation_id: str, file_id: str, user_id: str, db: AsyncIOMotorDatabase
) -> dict:
    if not ObjectId.is_valid(file_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "File not found")

    doc = await db.files.find_one(
        {"_id": ObjectId(file_id), "conversation_id": conversation_id, "user_id": user_id}
    )
    if doc is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "File not found")
    return doc


@router.post("", response_model=FileOut, status_code=status.HTTP_201_CREATED)
async def upload_file(
    conversation_id: str,
    file: UploadFile = File(...),
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
    storage: StorageBackend = Depends(get_storage),
) -> FileOut:
    await get_owned_conversation(conversation_id, current_user.id, db)

    data = await file.read()
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Uploaded file is empty")
    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    if len(data) > max_bytes:
        raise HTTPException(
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            f"File exceeds the {settings.max_upload_size_mb}MB upload limit",
        )

    filename = file.filename or "upload"
    mimetype = file.content_type or mimetypes.guess_type(filename)[0] or "application/octet-stream"
    kind = classify_kind(filename, mimetype)

    extracted_text = extract_text(data, kind)
    if extracted_text and len(extracted_text) > settings.extracted_text_max_chars:
        extracted_text = (
            extracted_text[: settings.extracted_text_max_chars]
            + "\n\n[... truncated, file too long to include in full ...]"
        )

    storage_key = f"{conversation_id}/{uuid.uuid4().hex}_{filename}"
    await storage.save(storage_key, data)

    now = datetime.now(timezone.utc)
    doc = {
        "conversation_id": conversation_id,
        "user_id": current_user.id,
        "filename": filename,
        "mimetype": mimetype,
        "kind": kind,
        "size": len(data),
        "storage_key": storage_key,
        "extracted_text": extracted_text,
        "created_at": now,
    }
    result = await db.files.insert_one(doc)
    doc["_id"] = result.inserted_id
    await metrics.record_file_upload(kind, len(data))

    preview = (extracted_text[:PREVIEW_CHARS] if extracted_text else None) or None
    return FileOut(**serialize_doc(doc), extracted_text_preview=preview)


@router.get("/{file_id}/download")
async def download_file(
    conversation_id: str,
    file_id: str,
    current_user: UserOut = Depends(get_current_user),
    db: AsyncIOMotorDatabase = Depends(get_db),
    storage: StorageBackend = Depends(get_storage),
):
    await get_owned_conversation(conversation_id, current_user.id, db)
    doc = await get_owned_file(conversation_id, file_id, current_user.id, db)

    redirect_url = storage.download_url(doc["storage_key"])
    if redirect_url:
        return RedirectResponse(redirect_url)

    data = await storage.load(doc["storage_key"])
    return StreamingResponse(
        iter([data]),
        media_type=doc["mimetype"],
        headers={"Content-Disposition": f'attachment; filename="{doc["filename"]}"'},
    )
