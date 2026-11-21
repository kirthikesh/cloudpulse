import asyncio
import logging
import os
import socket
import time
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest
from pydantic import BaseModel, Field, field_validator

from . import __version__
from .checker import run_forever
from .config import get_settings
from .store import Store

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

STATIC_DIR = Path(__file__).parent / "static"
STARTED_AT = time.time()
HTTP_REQUESTS = Counter("cloudpulse_http_requests_total", "API requests", ["method", "path", "status"])


class MonitorIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    url: str = Field(max_length=500)

    @field_validator("url")
    @classmethod
    def valid_http_url(cls, v: str) -> str:
        parsed = urlparse(v)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError("url must start with http:// or https://")
        return v


def create_app(store: Store | None = None) -> FastAPI:
    settings = get_settings()
    store = store or Store(settings)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        task = None
        if settings.role in ("worker", "all"):
            task = asyncio.create_task(
                run_forever(store, settings.check_interval_seconds, settings.check_timeout_seconds)
            )
        yield
        if task:
            task.cancel()

    app = FastAPI(title="CloudPulse", version=__version__, lifespan=lifespan)

    @app.middleware("http")
    async def count_requests(request, call_next):
        response = await call_next(request)
        route = request.scope.get("route")
        path = route.path if route else "unmatched"
        HTTP_REQUESTS.labels(request.method, path, response.status_code).inc()
        return response

    @app.get("/healthz")
    def healthz():
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz():
        try:
            store.ping()
        except Exception as exc:
            raise HTTPException(503, f"dynamodb not reachable: {type(exc).__name__}") from exc
        return {"status": "ready"}

    @app.get("/metrics")
    def metrics():
        return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.get("/api/info")
    def info():
        return {
            "app": "cloudpulse",
            "version": __version__,
            "env": settings.app_env,
            "image_tag": os.getenv("IMAGE_TAG", "dev"),
            "build_id": os.getenv("BUILD_ID", "local"),
            "git_sha": os.getenv("GIT_SHA", "local"),
            "pod": os.getenv("POD_NAME", socket.gethostname()),
            "node": os.getenv("NODE_NAME", "local"),
            "uptime_seconds": int(time.time() - STARTED_AT),
        }

    @app.get("/api/monitors")
    def list_monitors():
        return store.list_monitors()

    @app.post("/api/monitors", status_code=201)
    def create_monitor(body: MonitorIn):
        return store.create_monitor(body.name, body.url)

    @app.delete("/api/monitors/{monitor_id}", status_code=204)
    def delete_monitor(monitor_id: str):
        if not store.delete_monitor(monitor_id):
            raise HTTPException(404, "monitor not found")

    @app.get("/api/monitors/{monitor_id}/checks")
    def list_checks(monitor_id: str, limit: int = Query(30, ge=1, le=200)):
        if not store.get_monitor(monitor_id):
            raise HTTPException(404, "monitor not found")
        return store.list_checks(monitor_id, limit)

    @app.get("/api/summary")
    def summary():
        monitors = store.list_monitors()
        up = sum(1 for m in monitors if m.get("status") == "up")
        down = sum(1 for m in monitors if m.get("status") == "down")
        latencies = [m["last_latency_ms"] for m in monitors if m.get("last_latency_ms") is not None]
        checked = up + down
        return {
            "total": len(monitors),
            "up": up,
            "down": down,
            "pending": len(monitors) - checked,
            "uptime_pct": round(100 * up / checked, 1) if checked else None,
            "avg_latency_ms": round(sum(latencies) / len(latencies), 1) if latencies else None,
        }

    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

    @app.get("/", include_in_schema=False)
    def dashboard():
        return FileResponse(STATIC_DIR / "index.html")

    return app


app = create_app() if os.getenv("CLOUDPULSE_NO_AUTOAPP") != "1" else None
