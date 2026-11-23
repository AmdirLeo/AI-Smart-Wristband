"""企业微信群告警分发测试：用本地 mock webhook 接收，验证消息与触发点。"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

received = []
server = None
thread = None


class _MockHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n).decode("utf-8"))
        received.append(body)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"errcode":0}')

    def log_message(self, *args):  # 静默
        pass


@pytest.fixture
def mock_webhook(tmp_path, monkeypatch):
    global server, thread, received
    received = []
    server = HTTPServer(("127.0.0.1", 0), _MockHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}/hook"
    cfg = tmp_path / "guardians.json"
    cfg.write_text(
        json.dumps({"wearer_name": "测试奶奶",
                    "webhooks": [{"name": "测试群", "url": url}]}, ensure_ascii=False),
        encoding="utf-8",
    )
    monkeypatch.setenv("WECOM_GUARDIANS_FILE", str(cfg))
    yield url
    server.shutdown()
    server.server_close()


def _wait(n, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline and len(received) < n:
        time.sleep(0.05)
    return received[:n]


def test_sos_and_cancel_dispatch(mock_webhook):
    from app import create_app
    from fastapi.testclient import TestClient

    with TestClient(create_app(access_token="test-secret")) as client:
        client.headers["Authorization"] = "Bearer test-secret"
        uuid = "550e8400-e29b-41d4-a716-446655440000"
        r = client.post("/api/events/sos", json={"request_id": uuid})
        assert r.status_code == 200
        msgs = _wait(1)
        assert msgs, "SOS 创建后应推送群告警"
        content = msgs[0]["markdown"]["content"]
        assert "SOS" in content and "测试奶奶" in content

        r = client.post(f"/api/events/{uuid}/cancel")
        assert r.status_code == 200
        msgs = _wait(2)
        assert len(msgs) == 2 and "取消" in msgs[1]["markdown"]["content"]

        # 终态后再次取消不重复推送
        r = client.post(f"/api/events/{uuid}/cancel")
        assert r.status_code == 200
        assert len(_wait(2)) == 2


def test_suspected_fall_dispatches_alert(mock_webhook):
    from app import create_app
    from fastapi.testclient import TestClient

    with TestClient(create_app(access_token="test-secret")) as client:
        client.headers["Authorization"] = "Bearer test-secret"
        rec = client.get("/api/samples/fall").json()
        r = client.post("/api/predict", json={"samples": rec["samples"]})
        assert r.status_code == 200
        assert r.json()["event"] is not None
        msgs = _wait(1)
        assert msgs and "疑似跌倒" in msgs[0]["markdown"]["content"]


def test_no_config_is_silent(tmp_path, monkeypatch):
    monkeypatch.setenv("WECOM_GUARDIANS_FILE", str(tmp_path / "none.json"))
    from app import create_app
    from fastapi.testclient import TestClient

    with TestClient(create_app(access_token="test-secret")) as client:
        client.headers["Authorization"] = "Bearer test-secret"
        r = client.post("/api/events/sos",
                        json={"request_id": "550e8400-e29b-41d4-a716-446655440000"})
        assert r.status_code == 200  # 未配置告警不影响接口本身


def test_multi_channel_payload_shapes(tmp_path, monkeypatch):
    """钉钉与 PushPlus 渠道分别收到各自格式的 payload。"""
    received = []

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n).decode("utf-8"))
            received.append((self.path, body))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"code":0}')

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), H)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    cfg = tmp_path / "guardians.json"
    cfg.write_text(json.dumps({
        "wearer_name": "测试奶奶",
        "webhooks": [
            {"type": "dingtalk", "name": "钉钉", "url": url + "/dingtalk"},
            {"type": "pushplus", "name": "pushplus", "token": "tok123", "url": url + "/pushplus"},
        ]
    }, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setenv("WECOM_GUARDIANS_FILE", str(cfg))

    from app import create_app
    from fastapi.testclient import TestClient
    with TestClient(create_app(access_token="test-secret")) as client:
        client.headers["Authorization"] = "Bearer test-secret"
        uuid = "550e8400-e29b-41d4-a716-446655440000"
        r = client.post("/api/events/sos", json={"request_id": uuid})
        assert r.status_code == 200
        deadline = time.time() + 3
        while time.time() < deadline and len(received) < 2:
            time.sleep(0.05)

    server.shutdown()
    server.server_close()
    assert len(received) == 2
    paths = {p for p, _ in received}
    assert paths == {"/dingtalk", "/pushplus"}
    ding = next(b for p, b in received if p == "/dingtalk")
    pp = next(b for p, b in received if p == "/pushplus")
    assert ding["msgtype"] == "markdown" and "SOS" in ding["markdown"]["text"]
    assert pp["token"] == "tok123" and "SOS" in pp["title"]
