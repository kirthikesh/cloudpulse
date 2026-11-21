import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    app_env: str
    table_name: str
    aws_region: str
    # "api" serves HTTP only, "worker" runs health checks only, "all" does both (local dev)
    role: str
    check_interval_seconds: int
    check_timeout_seconds: float
    result_ttl_days: int
    dynamodb_endpoint: str | None


def get_settings() -> Settings:
    return Settings(
        app_env=os.getenv("APP_ENV", "local"),
        table_name=os.getenv("TABLE_NAME", "cloudpulse-local"),
        aws_region=os.getenv("AWS_REGION", "eu-west-1"),
        role=os.getenv("ROLE", "all"),
        check_interval_seconds=int(os.getenv("CHECK_INTERVAL_SECONDS", "60")),
        check_timeout_seconds=float(os.getenv("CHECK_TIMEOUT_SECONDS", "5")),
        result_ttl_days=int(os.getenv("RESULT_TTL_DAYS", "7")),
        dynamodb_endpoint=os.getenv("DYNAMODB_ENDPOINT") or None,
    )
