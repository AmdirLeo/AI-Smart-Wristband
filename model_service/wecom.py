"""企业微信群机器人告警（可选）。

配置 model_service/guardians.json（可被环境变量 WECOM_GUARDIANS_FILE 覆盖）：
{
  "wearer_name": "王奶奶",
  "webhooks": [
    {"name": "监护人微信群", "url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx"}
  ]
}

- webhooks 为空或文件不存在时静默跳过，不影响任何接口。
- 每次 SOS 创建 / SOS 取消 / 疑似跌倒告警时，向所有群推送一条 markdown 消息。
  群里拉入普通个人微信用户即可接收（无需人人安装企业微信）。
- 单个群发送失败只记日志，不影响其他群与接口本身。
"""
import asyncio
import json
import logging
import os
from datetime import datetime
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = ROOT / "guardians.json"
log = logging.getLogger("yian.wecom")

_KIND_TEXT = {"sos": "SOS 求助", "fall": "疑似跌倒"}


def config_path() -> Path:
    override = os.environ.get("WECOM_GUARDIANS_FILE")
    return Path(override) if override else DEFAULT_CONFIG


def load_guardians() -> dict:
    """读取监护人配置；返回 {} 表示未配置。"""
    path = config_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        webhooks = [w for w in data.get("webhooks", []) if w.get("url")]
        return {"wearer_name": data.get("wearer_name", ""), "webhooks": webhooks}
    except (json.JSONDecodeError, OSError):
        log.warning("guardians 配置读取失败：%s", path)
        return {}


def configured() -> bool:
    return bool(load_guardians().get("webhooks"))


def _build_message(event: dict, cfg: dict) -> str:
    kind = event.get("kind", "fall")
    title = f"【颐安云护】{_KIND_TEXT.get(kind, kind)}告警"
    when = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    status = event.get("status", "")
    status_text = {
        "help_requested": "已立即告警，请尽快联系老人核实",
        "pending": "已创建待确认事件（若误报将自动关闭）",
        "cancelled": "佩戴者已取消求助",
    }.get(status, status)
    wearer = cfg.get("wearer_name") or "佩戴者"
    return "\n".join([
        f"**{title}**",
        f"> 佩戴者：{wearer}",
        f"> 时间：{when}",
        f"> 状态：{status_text}",
        "",
        "本消息由手环/手机自动推送（演示项目，未接入真实短信/电话）。",
    ])


async def _post_one(name: str, url: str, payload: dict):
    async with httpx.AsyncClient(timeout=httpx.Timeout(5.0)) as client:
        r = await client.post(url, json=payload)
        r.raise_for_status()
        return r.status_code


async def notify_event(event: dict):
    """向所有配置的企业微信群推送事件告警。所有异常都在本函数内吞掉。"""
    cfg = load_guardians()
    webhooks = cfg.get("webhooks", [])
    if not webhooks:
        return
    payload = {"msgtype": "markdown", "markdown": {"content": _build_message(event, cfg)}}
    results = await asyncio.gather(
        *(_post_one(w["name"], w["url"], payload) for w in webhooks),
        return_exceptions=True,
    )
    for w, r in zip(webhooks, results):
        if isinstance(r, BaseException):
            log.warning("微信告警推送失败[%s]：%r", w.get("name", "?"), r)
