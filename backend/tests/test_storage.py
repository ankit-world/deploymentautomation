import pytest

from app.services.storage import LocalDiskStorage


@pytest.mark.asyncio
async def test_local_disk_storage_save_load_delete(tmp_path):
    storage = LocalDiskStorage(tmp_path / "uploads")

    key = "conv123/abc_test.txt"
    await storage.save(key, b"hello world")

    loaded = await storage.load(key)
    assert loaded == b"hello world"

    await storage.delete(key)
    with pytest.raises(FileNotFoundError):
        await storage.load(key)


@pytest.mark.asyncio
async def test_local_disk_storage_delete_missing_is_noop(tmp_path):
    storage = LocalDiskStorage(tmp_path / "uploads")
    await storage.delete("does/not/exist.txt")  # should not raise


def test_local_disk_storage_rejects_path_traversal(tmp_path):
    storage = LocalDiskStorage(tmp_path / "uploads")
    with pytest.raises(ValueError):
        storage._resolve("../../etc/passwd")


def test_local_disk_storage_download_url_is_none(tmp_path):
    storage = LocalDiskStorage(tmp_path / "uploads")
    assert storage.download_url("anything") is None
