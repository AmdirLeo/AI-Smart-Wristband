"""监护人告警分发（可选）：支持企业微信 / 钉钉 / PushPlus / Server酱。

配置 model_service/guardians.json（可被环境变量 WECOM_GUARDIANS_FILE 覆盖）：
{
  "wearer_name": "王奶奶",
  "webhooks": [
    { "type": "wecom",      "name": "企业微信内部群", "url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx" },
    { "type": "dingtalk",   "name": "钉钉群",         "url": "https://oapi.dingtalk.com/robot/send?access_token=xxx" },
    { "type": "pushplus",   "name": "微信PushPlus",   "token": "pushplus官网微信扫码登录后获取" },
    { "type": "serverchan", "name": "微信Server酱",   "token": "sct.ftqq.com的SendKey" }
  ]
}

- type 缺省按 "wecom" 处理；每条 SOS/取消/疑似跌倒事件向全部渠道各推一条。
- pushplus / serverchan 的消息直接出现在绑定者的微信里（服务号推送）。
- webhooks 为空或文件不存在时静默跳过；单个渠道失败只记日志。
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
log = logging.getLogger("yian.notify")

_KIND_TEXT = {"sos": "SOS 求助", "fall": "疑似跌倒"}
PUSHPLUS_URL = "http://www.pushplus.plus/send"
SERVERCHAN_URL = "https://sctapi.ftqq.com/{token}.send"


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
        webhooks = [w for w in data.get("webhooks", []) if _url_for(w)]
        return {"wearer_name": data.get("wearer_name", ""), "webhooks": webhooks}
    except (json.JSONDecodeError, OSError):
        log.warning("guardians 配置读取失败：%s", path)
        return {}


def configured() -> bool:
    return bool(load_guardians().get("webhooks"))


def _entry_type(entry: dict) -> str:
    return (entry.get("type") or "wecom").lower()


def _url_for(entry: dict) -> str:
    t = _entry_type(entry)
    if t == "pushplus":
        return entry.get("url") or PUSHPLUS_URL
    if t == "serverchan":
        token = entry.get("token", "")
        return entry.get("url") or SERVERCHAN_URL.format(token=token)
    return entry.get("url", "")


def _content_for(event: dict, cfg: dict) -> str:
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


def _payload_for(entry: dict, title: str, content: str) -> dict:
    t = _entry_type(entry)
    if t == "dingtalk":
        return {"msgtype": "markdown", "markdown": {"title": title[:20], "text": content}}
    if t == "pushplus":
        return {"token": entry.get("token", ""), "title": title,
                "content": content, "template": "markdown"}
    if t == "serverchan":
        return {"title": title, "desp": content}
    return {"msgtype": "markdown", "markdown": {"content": content}}  # wecom


async def _post_one(name: str, url: str, payload: dict):
    async with httpx.AsyncClient(timeout=httpx.Timeout(5.0)) as client:
        r = await client.post(url, json=payload)
        r.raise_for_status()
        return r.status_code


async def notify_event(event: dict):
    """向所有配置的渠道推送事件告警。所有异常都在本函数内吞掉。"""
    cfg = load_guardians()
    webhooks = cfg.get("webhooks", [])
    if not webhooks:
        return
    title = f"【颐安云护】{_KIND_TEXT.get(event.get('kind', 'fall'), '事件')}告警"
    content = _content_for(event, cfg)
    jobs = []
    for w in webhooks:
        jobs.append(_post_one(w.get("name", _entry_type(w)), _url_for(w), _payload_for(w, title, content)))
    results = await asyncio.gather(*jobs, return_exceptions=True)
    for w, r in zip(webhooks, results):
        if isinstance(r, BaseException):
            log.warning("告警推送失败[%s]：%r", w.get("name", "?"), r)
