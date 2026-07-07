from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

from app.models.file import FileAttachmentSummary


class MessageCreate(BaseModel):
    content: str = Field(min_length=1)
    # Ids of files already uploaded via POST /conversations/{id}/files, to attach to this
    # message (images go to the LLM as vision input, docs' extracted text is injected).
    file_ids: list[str] = Field(default_factory=list)


class MessageOut(BaseModel):
    id: str
    conversation_id: str
    role: Literal["user", "assistant"]
    content: str
    attachments: list[FileAttachmentSummary] = Field(default_factory=list)
    created_at: datetime


class MessagePairOut(BaseModel):
    user_message: MessageOut
    assistant_message: MessageOut
