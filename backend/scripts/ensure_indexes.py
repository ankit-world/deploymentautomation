"""One-time (idempotent, safe to rerun) operational script: creates the MongoDB indexes this app
relies on for correctness and performance. Not run from app startup/lifespan on purpose — see
app/core/db.py's connect_db() docstring for why lifespan must never do real DB I/O (tests run the
real lifespan on every one of ~45 test cases; a blocking index-creation call there would either
hang against the test suite's unreachable default MongoDB URI, or race every container replica
into creating the same indexes concurrently on every restart in production). Index creation is
naturally a deployment-time concern, not a request-hot-path one.

Run manually against whichever MongoDB Atlas cluster `backend/.env` points at:

    cd backend && .venv/Scripts/python -m scripts.ensure_indexes

Safe to rerun any time (e.g. after a fresh cluster, or whenever this file's index list changes) —
`create_index` is a no-op if an equivalent index already exists.

Without the unique index on `users.email` specifically, `POST /auth/signup`'s check-then-insert
has a real TOCTOU race: two concurrent signups with the same email could both pass the
`find_one` check and both succeed, creating duplicate accounts. `app/routers/auth.py`'s signup
handler catches `DuplicateKeyError` from the insert as a second line of defense once this index
exists — but the index is what actually makes the constraint enforced, not just the app-level
check.
"""

import asyncio

from motor.motor_asyncio import AsyncIOMotorClient

from app.core.config import settings


async def main() -> None:
    client = AsyncIOMotorClient(settings.mongodb_uri)
    db = client[settings.mongodb_db_name]

    print(f"Ensuring indexes on database '{settings.mongodb_db_name}'...")

    name = await db.users.create_index("email", unique=True)
    print(f"  users.{name} (unique)")

    name = await db.conversations.create_index([("user_id", 1), ("updated_at", -1)])
    print(f"  conversations.{name}")

    name = await db.messages.create_index([("conversation_id", 1), ("created_at", 1)])
    print(f"  messages.{name}")

    name = await db.files.create_index([("conversation_id", 1)])
    print(f"  files.{name}")
    name = await db.files.create_index([("user_id", 1)])
    print(f"  files.{name}")

    client.close()
    print("Done.")


if __name__ == "__main__":
    asyncio.run(main())
