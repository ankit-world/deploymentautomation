from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # NOTE: these defaults are for local dev convenience only. Never rely on them in any
    # deployed environment — production reads real values from AWS Secrets Manager (session 08).
    mongodb_uri: str = "mongodb://localhost:27017"
    mongodb_db_name: str = "chatapp"

    jwt_secret: str = "dev-secret-change-me-this-is-not-secure-32bytes+"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 7

    redis_url: str | None = None
    rate_limit_max_requests: int = 20
    rate_limit_window_seconds: int = 60

    frontend_origin: str = "http://localhost:3000"

    # --- Structured logging (see app/core/logging_config.py) ---
    log_level: str = "INFO"

    # --- Session 02: LLM ---
    # OPENAI_BASE_URL points at a third-party OpenAI-*compatible* gateway (Euri/Euron), not
    # api.openai.com. See docs/ARCHITECTURE.md "LLM integration" for what was verified about it
    # (model catalog, streaming shape, vision support).
    openai_api_key: str = ""
    openai_base_url: str | None = None
    openai_model: str = "gpt-4o-mini"
    # Whether the configured model accepts vision `image_url` content parts. Verified True for
    # gpt-4o-mini on the Euri gateway (see ARCHITECTURE.md). If you switch openai_model to a
    # non-vision model, flip this so image attachments degrade to a text note instead of an
    # API error.
    vision_supported: bool = True

    # --- Session 02: files ---
    max_upload_size_mb: int = 20
    upload_dir: str = "uploads"
    extracted_text_max_chars: int = 20000
    # S3 storage (stubbed interface now, real use starts session 08). Leave unset locally —
    # unset s3_bucket means the local-disk storage backend is used.
    s3_bucket: str | None = None
    aws_region: str | None = None

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


settings = Settings()
