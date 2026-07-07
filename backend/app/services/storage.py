"""Storage abstraction for file attachment bytes.

MongoDB only ever stores file *metadata* (filename, storage key, mimetype, size, extracted
text) — never the raw bytes (see docs/ARCHITECTURE.md "File storage"). The actual bytes live
behind this interface so the rest of the app doesn't care whether it's local disk (dev) or S3
(prod, from session 08 onward).
"""

import asyncio
from abc import ABC, abstractmethod
from pathlib import Path

from app.core.config import settings


class StorageBackend(ABC):
    @abstractmethod
    async def save(self, key: str, data: bytes) -> str:
        """Persists data under key, returns the key actually used (backends may normalize it)."""

    @abstractmethod
    async def load(self, key: str) -> bytes:
        """Returns the raw bytes stored under key."""

    @abstractmethod
    async def delete(self, key: str) -> None:
        """Removes the object at key. Should not raise if it's already gone."""

    def download_url(self, key: str) -> str | None:
        """Returns a URL the client should be redirected to for downloads (e.g. an S3
        presigned URL), or None if the caller should stream the bytes itself (local disk).
        """
        return None


class LocalDiskStorage(StorageBackend):
    """Dev storage backend: files under a gitignored directory on local disk."""

    def __init__(self, base_dir: str | Path):
        self.base_dir = Path(base_dir).resolve()
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def _resolve(self, key: str) -> Path:
        # `key` may contain subdirectories (e.g. "<conversation_id>/<uuid>_name.pdf"). Guard
        # against path traversal escaping base_dir.
        path = (self.base_dir / key).resolve()
        if self.base_dir != path and self.base_dir not in path.parents:
            raise ValueError(f"Invalid storage key: {key!r}")
        return path

    async def save(self, key: str, data: bytes) -> str:
        path = self._resolve(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        await asyncio.to_thread(path.write_bytes, data)
        return key

    async def load(self, key: str) -> bytes:
        path = self._resolve(key)
        return await asyncio.to_thread(path.read_bytes)

    async def delete(self, key: str) -> None:
        path = self._resolve(key)
        await asyncio.to_thread(path.unlink, True)  # missing_ok=True


class S3Storage(StorageBackend):
    """Prod storage backend (session 08+). Interface-shaped now; boto3 is only imported/used
    lazily so this class can exist (and even be unit-tested with a mocked client) without real
    AWS credentials or network access being available yet.
    """

    def __init__(self, bucket: str, region: str | None = None):
        self.bucket = bucket
        self.region = region
        self._client = None

    def _get_client(self):
        if self._client is None:
            import boto3

            self._client = boto3.client("s3", region_name=self.region)
        return self._client

    async def save(self, key: str, data: bytes) -> str:
        client = self._get_client()
        await asyncio.to_thread(client.put_object, Bucket=self.bucket, Key=key, Body=data)
        return key

    async def load(self, key: str) -> bytes:
        client = self._get_client()
        obj = await asyncio.to_thread(client.get_object, Bucket=self.bucket, Key=key)
        return obj["Body"].read()

    async def delete(self, key: str) -> None:
        client = self._get_client()
        await asyncio.to_thread(client.delete_object, Bucket=self.bucket, Key=key)

    def download_url(self, key: str) -> str | None:
        client = self._get_client()
        return client.generate_presigned_url(
            "get_object", Params={"Bucket": self.bucket, "Key": key}, ExpiresIn=300
        )


_local_storage: LocalDiskStorage | None = None


def get_storage() -> StorageBackend:
    """FastAPI dependency: local disk unless S3_BUCKET is configured."""
    if settings.s3_bucket:
        return S3Storage(settings.s3_bucket, settings.aws_region)

    global _local_storage
    if _local_storage is None:
        _local_storage = LocalDiskStorage(settings.upload_dir)
    return _local_storage
