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

    frontend_origin: str = "http://localhost:3000"

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


settings = Settings()
