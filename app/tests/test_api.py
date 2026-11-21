import asyncio

import httpx

from cloudpulse import checker


def test_health_and_ready(client):
    assert client.get("/healthz").json() == {"status": "ok"}
    assert client.get("/readyz").status_code == 200


def test_dashboard_served(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "CloudPulse" in r.text
    assert client.get("/static/app.js").status_code == 200
    assert client.get("/static/styles.css").status_code == 200


def test_info_reports_build_metadata(client, monkeypatch):
    monkeypatch.setenv("IMAGE_TAG", "42-abc1234")
    body = client.get("/api/info").json()
    assert body["env"] == "test"
    assert body["image_tag"] == "42-abc1234"


def test_monitor_crud(client):
    r = client.post("/api/monitors", json={"name": "GitHub", "url": "https://github.com"})
    assert r.status_code == 201
    mon = r.json()
    assert mon["status"] == "pending"

    assert [m["id"] for m in client.get("/api/monitors").json()] == [mon["id"]]
    assert client.get(f"/api/monitors/{mon['id']}/checks").json() == []

    assert client.delete(f"/api/monitors/{mon['id']}").status_code == 204
    assert client.get("/api/monitors").json() == []
    assert client.delete(f"/api/monitors/{mon['id']}").status_code == 404


def test_rejects_bad_url(client):
    r = client.post("/api/monitors", json={"name": "bad", "url": "ftp://example.com"})
    assert r.status_code == 422


def test_summary_and_checks(client, store):
    a = store.create_monitor("A", "https://a.example")
    b = store.create_monitor("B", "https://b.example")
    store.create_monitor("C", "https://c.example")
    store.record_check(a["id"], True, 200, 100.0)
    store.record_check(b["id"], False, 503, 300.0)

    s = client.get("/api/summary").json()
    assert s == {"total": 3, "up": 1, "down": 1, "pending": 1, "uptime_pct": 50.0, "avg_latency_ms": 200.0}

    checks = client.get(f"/api/monitors/{b['id']}/checks").json()
    assert checks[0]["up"] is False and checks[0]["status_code"] == 503


def test_checker_marks_up_and_down(store, monkeypatch):
    ok = store.create_monitor("ok", "https://ok.example")
    bad = store.create_monitor("bad", "https://bad.example")

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "bad.example":
            raise httpx.ConnectError("boom", request=request)
        return httpx.Response(200)

    real_client = httpx.AsyncClient
    monkeypatch.setattr(
        checker.httpx, "AsyncClient", lambda **kw: real_client(transport=httpx.MockTransport(handler), **kw)
    )

    assert asyncio.run(checker.run_once(store, timeout=1)) == 2
    assert store.get_monitor(ok["id"])["status"] == "up"
    down = store.get_monitor(bad["id"])
    assert down["status"] == "down"
    assert store.list_checks(bad["id"])[0]["error"] == "ConnectError"


def test_metrics_endpoint(client):
    client.get("/healthz")
    body = client.get("/metrics").text
    assert "cloudpulse_http_requests_total" in body
