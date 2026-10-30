"""Bounded HTTP+SignalR probe of the local foundation; never prints credentials."""
from pathlib import Path
import concurrent.futures
import datetime
import json
import math
import os
import statistics
import time
import urllib.error
import urllib.request
import uuid
from websockets.sync.client import connect

ROOT = Path(__file__).resolve().parents[1]
BASE = os.environ.get("FRUITVISION_PROBE_URL", "http://127.0.0.1:5098").rstrip("/")
if BASE != "http://127.0.0.1:5098":
    tunnel = json.loads((ROOT / ".local/tunnel-state.json").read_text(encoding="utf-8-sig"))
    if BASE != tunnel.get("publicUrl") or not BASE.startswith("https://"):
        raise ValueError("Only the owned, recorded HTTPS tunnel may receive demo credentials.")
settings = json.loads((ROOT / ".local/runtime.json").read_text(encoding="utf-8-sig"))
password = settings["Demo"]["Password"]
checks = []


def request(path, data=None, token=None, method=None, raw=None, content_type="application/json"):
    headers = {"Content-Type": content_type}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    start = time.perf_counter()
    req = urllib.request.Request(BASE + path, data=body, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=8)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        payload = response.read()
        result = json.loads(payload) if payload and "json" in response.headers.get("Content-Type", "") else payload.decode()
        return response.status, result, time.perf_counter() - start


def check(name, condition):
    checks.append({"name": name, "passed": bool(condition)})
    if not condition:
        raise AssertionError(name)


def login(email):
    code, data, _ = request("/api/v1/auth/login", {"email": email, "password": password})
    check("login:" + email, code == 200 and "accessToken" in data)
    return data


report = {"startedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "baseUrl": BASE,
          "scope": "Kestrel-PostgreSQL-and-SignalR over the recorded URL; no AI or physical-phone capacity claim",
          "tlsVerificationDisabled": False}
try:
    check("readiness", request("/health/ready")[0] == 200)
    status, html, _ = request("/")
    check("web-client-served", status == 200 and "FruitVision" in html)
    status, swagger, _ = request("/v1/index.html")
    check("swagger-index-served", status == 200 and "swagger-ui" in swagger)
    status, schema, _ = request("/openapi/v1.json")
    check("openapi-bearer-and-relative-server", status == 200 and schema["servers"][0]["url"] == "/" and schema["components"]["securitySchemes"]["SessionBearer"]["scheme"] == "bearer")
    check("private-config-not-served", request("/.local/runtime.json")[0] == 404)
    check("unauthenticated-admin-denied", request("/api/v1/admin/stats")[0] == 401)
    check("malformed-json", request("/api/v1/auth/login", raw=b'{"email":')[0] == 400)
    check("oversize-before-db", request("/api/v1/auth/login", raw=b"x" * 50000)[0] == 413)
    check("wrong-content-type", request("/api/v1/auth/login", raw=b"hello", content_type="text/plain")[0] == 415)
    admin = login("admin@fruitvision.test")
    producer = login("producer@fruitvision.test")
    token = producer["accessToken"]
    status, stats, _ = request("/api/v1/admin/stats", token=admin["accessToken"])
    check("seed-counts", status == 200 and stats["users"] == 24 and stats["posts"] == 60 and stats["messages"] >= 480)
    report["actualCounts"] = stats
    code, conversations, _ = request("/api/v1/conversations", token=token)
    check("own-conversations", code == 200 and len(conversations["items"]) > 0)
    conversation_id = conversations["items"][0]["id"]
    socket_base = BASE.replace("https://", "wss://").replace("http://", "ws://")
    with connect(socket_base + "/hubs/fruitvision", additional_headers={"Authorization": "Bearer " + token},
                 open_timeout=5, close_timeout=3, max_size=32768, proxy=None) as ws:
        ws.send(json.dumps({"protocol": "json", "version": 1}) + "\x1e")
        check("signalr-handshake", ws.recv(timeout=5).rstrip("\x1e") == "{}")
        ws.send(json.dumps({"type": 1, "invocationId": "join", "target": "JoinConversation", "arguments": [conversation_id]}) + "\x1e")
        check("signalr-authorized-group", "error" not in json.loads(ws.recv(timeout=5).rstrip("\x1e")))
        key = uuid.uuid4().hex
        data = {"clientMessageId": key, "text": "Kiểm tra kết nối nền tảng (dữ liệu demo)."}
        status, message, _ = request(f"/api/v1/conversations/{conversation_id}/messages", data, token)
        check("message-persisted", status == 201)
        deadline = time.monotonic() + 8
        delivered = False
        while time.monotonic() < deadline:
            packet = ws.recv(timeout=max(.1, deadline - time.monotonic()))
            for frame in packet.split("\x1e"):
                if not frame:
                    continue
                event = json.loads(frame)
                if event.get("target") == "MessageCreated" and event["arguments"][0]["id"] == message["id"]:
                    delivered = True
            if delivered:
                break
        check("real-socket-realtime-delivery", delivered)
        code, repeated, _ = request(f"/api/v1/conversations/{conversation_id}/messages", data, token)
        check("idempotent-message-retry", code == 200 and repeated["id"] == message["id"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        observations = list(pool.map(lambda _: request("/api/v1/posts?limit=12"), range(30)))
    durations = sorted(row[2] * 1000 for row in observations)
    check("30-reads-6-clients-no-errors", all(row[0] == 200 for row in observations))
    report["smallReadProbe"] = {"requests": 30, "concurrency": 6, "p50Ms": round(statistics.median(durations), 2),
                                "p95Ms": round(durations[math.ceil(len(durations) * .95) - 1], 2),
                                "environment": BASE + "; seeded small database, no inference load; not production capacity"}
    check("logout", request("/api/v1/auth/logout", token=token, method="POST")[0] == 204)
    check("logout-token-invalid", request("/api/v1/auth/me", token=token)[0] == 401)
    request("/api/v1/auth/logout", token=admin["accessToken"], method="POST")
    report["status"] = "PASS"
except Exception as error:
    report["status"] = "FAIL"
    report["errorType"] = type(error).__name__
    raise
finally:
    report["checks"] = checks
    report["finishedUtc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    output = ROOT / ("docs/public-https-smoke.json" if BASE.startswith("https://") else "docs/live-smoke-final.json")
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": report["status"], "checks": len(checks), "receipt": str(output),
                      "smallReadProbe": report.get("smallReadProbe")}, ensure_ascii=False))
