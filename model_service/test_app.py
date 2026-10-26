"""Exercise the real saved model, input boundaries and simulated event lifecycle."""
import io
import csv
from copy import deepcopy
import json

from fastapi.testclient import TestClient
import pytest

from app import CONFIRM_SECONDS, MAX_BODY, ROOT, create_app
from pipeline import CSV_COLUMNS


@pytest.fixture
def client():
    with TestClient(create_app(access_token="test-secret")) as active:
        active.headers["Authorization"] = "Bearer test-secret"
        yield active


def signal(client, sample_id="fall"):
    r = client.get(f"/api/samples/{sample_id}")
    assert r.status_code == 200
    return {"samples": r.json()["samples"]}


def test_authentication_and_public_health(client):
    assert client.get("/health", headers={"Authorization": ""}).status_code == 200
    assert client.get("/", headers={"Authorization": ""}).status_code == 200
    for method, path in [("GET", "/api/samples"), ("POST", "/api/predict"),
                         ("POST", "/api/predict-csv"), ("GET", "/api/events/fake")]:
        assert client.request(method, path, headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_all_demo_cases_match_real_model_and_are_held_out(client):
    items = client.get("/api/samples").json()["samples"]
    assert len(items) == 4
    assert all("samples" not in item for item in items)
    held_out = client.app.state.artifact["report"]["protocol"]["test_subjects"]
    outcomes = set()
    for item in items:
        assert item["subject"] in held_out
        response = client.post("/api/predict", json=signal(client, item["id"]))
        assert response.status_code == 200
        result = response.json()
        assert result["label"] == item["expected_label"]
        outcomes.add((item["true_label"], int(result["label"] == "suspected_fall")))
        assert bool(result["event"]) == (result["label"] == "suspected_fall")
    assert outcomes == {(0, 0), (0, 1), (1, 0), (1, 1)}


def test_csv_and_json_inference_match(client):
    data = signal(client)
    text = io.StringIO()
    writer = csv.writer(text)
    writer.writerow(CSV_COLUMNS)
    writer.writerows(data["samples"])
    via_csv = client.post("/api/predict-csv", content="\ufeff" + text.getvalue(),
                          headers={"Content-Type": "text/csv"})
    via_json = client.post("/api/predict", json=data)
    assert via_csv.status_code == 200
    assert via_csv.json()["score"] == pytest.approx(via_json.json()["score"], abs=1e-12)


@pytest.mark.parametrize("body", [
    b'{}', b'{"samples":[[0,1,2]]}', b'{"samples":[[0,0,0,NaN,0,0,0]]}',
    b'{"samples": null}', b'not json',
])
def test_malformed_json_is_rejected_without_server_error(client, body):
    assert client.post("/api/predict", content=body).status_code == 422


def test_quality_checks_and_unknown_fields(client):
    data = signal(client)
    assert client.post("/api/predict", json={"samples": data["samples"][:10]}).status_code == 422
    gap = deepcopy(data)
    del gap["samples"][40:80]
    assert client.post("/api/predict", json=gap).status_code == 422
    assert client.post("/api/predict", json={**data, "true_label": 1}).status_code == 422
    data["samples"][3][1] = "infinity"
    assert client.post("/api/predict", json=data).status_code == 422


def test_csv_boundaries_and_body_limits(client):
    assert client.post("/api/predict-csv", content=b"wrong,header\n1,2").status_code == 422
    assert client.post("/api/predict-csv", content=b"\xff\xfe").status_code == 422
    for path in ["/api/predict", "/api/predict-csv"]:
        assert client.post(path, content=b" " * (MAX_BODY + 1)).status_code == 413


def test_extreme_finite_values_do_not_crash_model_service(client):
    data = signal(client)
    data["samples"][50][1] = 1e308
    assert client.post("/api/predict", json=data).status_code == 422


@pytest.mark.parametrize("choice,status", [("safe", "safe"), ("help", "help_requested")])
def test_confirmation_is_idempotent_and_cannot_change_final_status(client, choice, status):
    event = client.post("/api/predict", json=signal(client)).json()["event"]
    url = f"/api/events/{event['id']}/confirm"
    assert client.post(url, json={"choice": choice}).json()["status"] == status
    assert client.post(url, json={"choice": choice}).json()["status"] == status
    opposite = "help" if choice == "safe" else "safe"
    assert client.post(url, json={"choice": opposite}).status_code == 409
    assert client.get(f"/api/events/{event['id']}").json()["notification_mode"] == "simulation_only"


def test_timeout_uses_server_deadline_and_does_not_send_messages(client):
    event = client.post("/api/predict", json=signal(client)).json()["event"]
    assert event["deadline"] - event["created_at"] == CONFIRM_SECONDS
    client.app.state.events[event["id"]]["deadline"] = 0
    result = client.get(f"/api/events/{event['id']}").json()
    assert result["status"] == "simulated_notification"
    assert result["reason"] == "confirmation_timeout"
    assert result["notification_mode"] == "simulation_only"
    assert client.post(f"/api/events/{event['id']}/confirm", json={"choice": "safe"}).status_code == 409


def test_unknown_expired_events_and_invalid_confirmations(client):
    assert client.get("/api/events/missing").status_code == 404
    assert client.get("/api/samples/missing").status_code == 404
    event = client.post("/api/predict", json=signal(client)).json()["event"]
    assert client.post(f"/api/events/{event['id']}/confirm", json={"choice": "invalid"}).status_code == 422
    client.app.state.events[event["id"]]["created_at"] = 0
    assert client.get(f"/api/events/{event['id']}").status_code == 404


def test_retrained_model_requires_matching_demo_bundle(tmp_path):
    bundle = json.loads((ROOT / "demo_samples.json").read_text(encoding="utf-8"))
    bundle["model_sha256"] = "changed-model"
    target = tmp_path / "demo.json"
    target.write_text(json.dumps(bundle), encoding="utf-8")
    with pytest.raises(RuntimeError, match="regenerate"):
        with TestClient(create_app(samples_path=target)):
            pass
