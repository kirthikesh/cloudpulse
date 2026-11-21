import asyncio
import logging
import time

import httpx
from prometheus_client import Counter, Histogram

from .store import Store

log = logging.getLogger("cloudpulse.checker")

CHECKS_TOTAL = Counter("cloudpulse_checks_total", "Health checks run", ["result"])
CHECK_LATENCY = Histogram("cloudpulse_check_latency_seconds", "Latency of monitored URLs")


async def check_one(client: httpx.AsyncClient, store: Store, monitor: dict) -> dict:
    start = time.perf_counter()
    try:
        resp = await client.get(monitor["url"], follow_redirects=True)
        latency = (time.perf_counter() - start) * 1000
        up = resp.status_code < 400
        result = store.record_check(monitor["id"], up, resp.status_code, latency)
    except httpx.HTTPError as exc:
        latency = (time.perf_counter() - start) * 1000
        up = False
        result = store.record_check(monitor["id"], False, None, latency, error=type(exc).__name__)
    CHECKS_TOTAL.labels(result="up" if up else "down").inc()
    CHECK_LATENCY.observe(latency / 1000)
    return result


async def run_once(store: Store, timeout: float) -> int:
    monitors = store.list_monitors()
    async with httpx.AsyncClient(timeout=timeout, headers={"User-Agent": "CloudPulse/1.0"}) as client:
        await asyncio.gather(*(check_one(client, store, m) for m in monitors))
    return len(monitors)


async def run_forever(store: Store, interval: int, timeout: float) -> None:
    log.info("checker started, interval=%ss", interval)
    while True:
        try:
            count = await run_once(store, timeout)
            log.info("checked %d monitors", count)
        except Exception:  # keep the loop alive whatever happens
            log.exception("check cycle failed")
        await asyncio.sleep(interval)
