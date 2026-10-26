"""Single-process demonstration service; no real emergency messages are sent."""
from contextlib import asynccontextmanager
from copy import deepcopy
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import threading
import time
import uuid

import joblib
import numpy as np
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field, FiniteFloat, ValidationError
from starlette.concurrency import run_in_threadpool

try:
    from .pipeline import CSV_COLUMNS, DataQualityError, predict_streams
except ImportError:
    from pipeline import CSV_COLUMNS, DataQualityError, predict_streams

ROOT = Path(__file__).resolve().parent
MAX_BODY = 2 * 1024 * 1024
MAX_SAMPLES = 4000
CONFIRM_SECONDS = 20
EVENT_TTL = 3600
MAX_EVENTS = 512
Sample = tuple[FiniteFloat, FiniteFloat, FiniteFloat, FiniteFloat,
               FiniteFloat, FiniteFloat, FiniteFloat]


class SignalInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    samples: list[Sample] = Field(min_length=3, max_length=MAX_SAMPLES)


class Confirmation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    choice: str = Field(pattern="^(safe|help)$")


async def limited_body(request: Request) -> bytes:
    chunks, size = [], 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > MAX_BODY:
            raise HTTPException(413, "上传内容超过 2 MB，请使用一段 10–20 秒记录。")
        chunks.append(chunk)
    return b"".join(chunks)


def validated_json(schema, body: bytes):
    try:
        return schema.model_validate_json(body)
    except ValidationError:
        raise HTTPException(422, "数据格式不正确，请检查字段、有限数值及记录数量。") from None


def create_app(model_path: Path | None = None, samples_path: Path | None = None,
               access_token: str | None = None) -> FastAPI:
    model_path = model_path or ROOT / "model.joblib"
    samples_path = samples_path or ROOT / "demo_samples.json"
    token = os.environ.get("DEMO_ACCESS_TOKEN", "") if access_token is None else access_token

    @asynccontextmanager
    async def lifespan(app):
        app.state.artifact = joblib.load(model_path)
        app.state.demo = json.loads(samples_path.read_text(encoding="utf-8"))
        digest = hashlib.sha256(model_path.read_bytes()).hexdigest()
        if app.state.demo["model_sha256"] != digest:
            raise RuntimeError("Model changed: regenerate demo_samples.json with prepare_demo.py")
        app.state.events = {}
        app.state.event_lock = threading.Lock()
        app.state.predict_lock = threading.Lock()
        yield

    app = FastAPI(title="颐安·云护演示", lifespan=lifespan, docs_url=None, redoc_url=None,
                  openapi_url=None)

    def authenticate(authorization: str | None = Header(default=None)):
        if token and not secrets.compare_digest((authorization or "").encode("utf-8"),
                                                f"Bearer {token}".encode("utf-8")):
            raise HTTPException(401, "请输入正确的演示访问口令。",
                                headers={"WWW-Authenticate": "Bearer"})

    api = APIRouter(prefix="/api", dependencies=[Depends(authenticate)])

    @app.get("/", include_in_schema=False)
    def index():
        return FileResponse(ROOT / "static" / "index.html", headers={"Cache-Control": "no-store"})

    @app.get("/health")
    def health():
        return {"status": "ok", "mode": "demonstration"}

    @api.get("/info")
    def info():
        report = app.state.artifact["report"]
        return {"name": "颐安·云护", "mode": "whole_trial_demo", "columns": CSV_COLUMNS,
                "confirm_seconds": CONFIRM_SECONDS,
                "metrics": report["nested_subject_cv"]["rf"],
                "subjects": len(report["dataset"]["usable_subjects"]),
                "trials": report["dataset"]["usable_trials"]}

    @api.get("/samples")
    def samples():
        return {"source": app.state.demo["source"], "license": app.state.demo["license"],
                "samples": [{k: v for k, v in sample.items() if k != "samples"}
                            for sample in app.state.demo["records"]]}

    @api.get("/samples/{sample_id}")
    def sample(sample_id: str):
        for record in app.state.demo["records"]:
            if record["id"] == sample_id:
                return record
        raise HTTPException(404, "找不到这条演示记录。")

    def refresh_event(event):
        if event["status"] == "pending" and time.time() >= event["deadline"]:
            event["status"] = "simulated_notification"
            event["reason"] = "confirmation_timeout"

    def get_event_locked(event_id):
        event = app.state.events.get(event_id)
        if event is None or time.time() - event["created_at"] >= EVENT_TTL:
            app.state.events.pop(event_id, None)
            raise HTTPException(404, "演示事件已过期或服务已重启，请重新识别。")
        refresh_event(event)
        return event

    def classify(payload: SignalInput):
        values = np.asarray(payload.samples, dtype=float)
        try:
            with app.state.predict_lock, np.errstate(over="raise", invalid="raise", divide="raise"):
                result = predict_streams(app.state.artifact, values[:, :4], values[:, [0, 4, 5, 6]])
        except DataQualityError as exc:
            raise HTTPException(422, f"记录质量不符合要求：{exc}") from None
        except (ValueError, FloatingPointError, OverflowError):
            raise HTTPException(422, "无法处理记录，请检查数值范围和传感器单位。") from None
        result["event"] = None
        result["mode"] = "whole_trial_demo"
        if result["label"] == "suspected_fall":
            now = time.time()
            event = {"id": str(uuid.uuid4()), "status": "pending", "created_at": now,
                     "deadline": now + CONFIRM_SECONDS, "reason": None,
                     "notification_mode": "simulation_only"}
            with app.state.event_lock:
                for key in list(app.state.events):
                    if now - app.state.events[key]["created_at"] >= EVENT_TTL:
                        del app.state.events[key]
                if len(app.state.events) >= MAX_EVENTS:
                    del app.state.events[next(iter(app.state.events))]
                app.state.events[event["id"]] = event
            result["event"] = deepcopy(event)
        return result

    @api.post("/predict")
    async def predict(request: Request):
        payload = validated_json(SignalInput, await limited_body(request))
        return await run_in_threadpool(classify, payload)

    @api.post("/predict-csv")
    async def predict_csv(request: Request):
        raw = await limited_body(request)
        try:
            reader = csv.reader(io.StringIO(raw.decode("utf-8-sig")), strict=True)
            if next(reader, None) != list(CSV_COLUMNS):
                raise HTTPException(422, "CSV 表头须为：" + ",".join(CSV_COLUMNS))
            rows = []
            for row in reader:
                if not row:
                    continue
                rows.append(row)
                if len(rows) > MAX_SAMPLES:
                    raise HTTPException(422, "最多支持 4000 行采样记录。")
            payload = SignalInput(samples=rows)
        except (UnicodeError, csv.Error, ValidationError):
            raise HTTPException(422, "CSV 必须为 UTF-8 编码，且每行包含七个有限数值。") from None
        return await run_in_threadpool(classify, payload)

    @api.get("/events/{event_id}")
    def event_status(event_id: str):
        with app.state.event_lock:
            return deepcopy(get_event_locked(event_id))

    @api.post("/events/{event_id}/confirm")
    async def confirm(event_id: str, request: Request):
        payload = validated_json(Confirmation, await limited_body(request))
        target = "safe" if payload.choice == "safe" else "help_requested"
        with app.state.event_lock:
            event = get_event_locked(event_id)
            if event["status"] == target:
                return deepcopy(event)
            if event["status"] != "pending":
                raise HTTPException(409, "事件已处理或已超时，请刷新状态。")
            event["status"] = target
            event["reason"] = "user_confirmation"
            return deepcopy(event)

    app.include_router(api)
    return app


app = create_app()
