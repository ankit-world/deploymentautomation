from datetime import datetime
from typing import Literal

from pydantic import BaseModel

FileKind = Literal["image", "pdf", "docx", "xlsx", "other"]


class FileOut(BaseModel):
    id: str
    conversation_id: str
    filename: str
    mimetype: str
    kind: FileKind
    size: int
    extracted_text_preview: str | None = None
    created_at: datetime


class FileAttachmentSummary(BaseModel):
    """Minimal attachment info embedded in a MessageOut — enough for the frontend to render a
    preview/download affordance without a second round trip.
    """

    id: str
    filename: str
    mimetype: str
    kind: FileKind
    size: int
