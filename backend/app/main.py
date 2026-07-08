from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.core.db import close_db, connect_db
from app.core.redis_client import close_redis, connect_redis
from app.routers import auth, conversations, files, messages


@asynccontextmanager
async def lifespan(app: FastAPI):
    await connect_db()
    await connect_redis()
    yield
    # ECS sends SIGTERM on every rolling redeploy (session 11 made these automatic on every
    # push to main) — close both connection pools gracefully instead of the socket just being
    # dropped. See connect_db()/connect_redis() for why there's no real connectivity check here,
    # just client construction.
    await close_db()
    await close_redis()


app = FastAPI(title="ChatGPT-style App API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.frontend_origin],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(conversations.router)
app.include_router(messages.router)
app.include_router(files.router)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}
