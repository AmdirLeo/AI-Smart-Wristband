# App ↔ 模型服务接口约定

本文对应 `model_service/app.py` 的现有实现。当前为完整动作记录分类演示，接口无版本前缀；模型分数不是医学概率，通知仅为模拟。

## 1. 地址、认证与网络

本机服务地址为 `http://127.0.0.1:8000`。开发启动命令见根目录 README；所有 `/api/` 路径都基于同一个地址。

- 服务端未配置 `DEMO_ACCESS_TOKEN` 时，无需认证。
- 配置后，每个 `/api/` 请求需带 `Authorization: Bearer <口令>`；`GET /health` 和演示首页无需口令。
- JSON 请求使用 `Content-Type: application/json`。接口客户端不得把真实口令写进仓库或提交日志。
- `GET /docs`、`GET /openapi.json` 当前未启用，请使用本文对接。

真机同局域网联调时，将启动命令中的 `--host 127.0.0.1` 改为 `--host 0.0.0.0`，在本机防火墙允许对应连接，然后在 App 配置 `http://电脑的局域网IP:8000`。真机上的 `localhost` 指手机自身；Android 官方模拟器通常通过 `http://10.0.2.2:8000` 访问宿主机。若服务运行在 WSL，宿主机本地访问成功不保证局域网手机可达，需另行配置端口转发或在 Windows 侧启动服务。

原生 HTTP 客户端没有浏览器 CORS 限制，但 Android/iOS 可能限制明文 HTTP，可仅为本地开发配置例外，部署时使用 HTTPS。当前服务未启用跨域 CORS；若 App 是 H5/Web，请用开发代理转发 `/api` 和 `/health`，使浏览器同源访问。需要直接跨域时，再协调服务端增加明确的允许来源。

## 2. 路由总表

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/health` | 返回 `{"status":"ok","mode":"demonstration"}` |
| GET | `/api/info` | 返回 `name`、`mode`、`columns`、`confirm_seconds`、`metrics`、`subjects`、`trials` |
| GET | `/api/samples` | 返回 `source`、`license`、`samples`；此处 samples 为不含信号数组的样例元信息列表 |
| GET | `/api/samples/{id}` | 返回完整样例，其中 `samples` 为可提交推理的二维数组 |
| POST | `/api/predict` | 上传 JSON 六轴记录 |
| POST | `/api/predict-csv` | 上传原始 UTF-8 CSV 文本 |
| GET | `/api/events/{id}` | 查询事件状态 |
| POST | `/api/events/{id}/confirm` | 确认安全或求助 |

四个样例 ID：`normal`、`fall`、`false_positive`、`false_negative`。完整样例还包含 `id`、`title`、`subject`、`activity`、`source_file`、`true_label`、`expected_label`、`duration_s`；这些元信息不是推理输入，不能整个对象直接提交到 `/predict`。

## 3. 推理输入

`POST /api/predict` 请求体只能包含 `samples`：

```json
{"samples":[[0.00,0.01,0.02,1.00,0.2,0.1,0.3],[0.05,0.02,0.01,1.01,0.1,0.2,0.1]]}
```

上面两行仅展示格式，时长不足，直接发送会被拒绝。实际上传完整 10–20 秒记录，推荐约 15 秒。

| 列索引 | 名称 | 单位与约定 |
|---|---|---|
| 0 | `timestamp_s` | 秒，同一记录内的传感器采样时间，推荐从 0 开始；不能用蓝牙到包时间代替 |
| 1–3 | `ax_g, ay_g, az_g` | 三轴加速度，单位 g，保留重力；m/s² 除以 9.80665 转换 |
| 4–6 | `gx_dps, gy_dps, gz_dps` | 三轴角速度，单位 °/s；rad/s 乘以 180/π 转换 |

六轴应同步、使用一致的设备轴定义；建议稳定 20 Hz 或 50 Hz。服务端会对齐、重采样至 20 Hz。不要用全零数组代替未采集的陀螺仪。

约束：每行七个有限数字；每次请求不超过 2 MB、4000 行；共享记录时长 10–20 秒；采样间断不超过 0.75 秒，原始有效采样率至少 14 Hz。App 应发送严格递增时间戳并保留动作前后上下文。当前不能把 1–2 秒窗口或单个蓝牙包直接交给模型。

`POST /api/predict-csv` 使用 `Content-Type: text/csv`，请求体是 CSV 文本，**不是 multipart 表单**。表头和顺序必须为：

```csv
timestamp_s,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps
```

## 4. 推理结果

成功返回 HTTP 200；以下是疑似跌倒响应的结构示例，数值、ID 和时间戳仅为示意：

```json
{
  "label": "suspected_fall",
  "score": 0.9805510706095325,
  "threshold": 0.2009596081649438,
  "note": "Uncalibrated whole-trial score; not a real-time alarm decision.",
  "mode": "whole_trial_demo",
  "event": {
    "id": "3f54285b-e464-40f2-aaca-30e1bffb0416",
    "status": "pending",
    "created_at": 1793000000.0,
    "deadline": 1793000020.0,
    "reason": null,
    "notification_mode": "simulation_only"
  }
}
```

- `label` 只有 `non_fall` 和 `suspected_fall`；App 以返回的标签为准，不硬编码阈值。`score >= threshold` 时判为疑似跌倒。
- `score` 是未经校准的分类分数，不显示为“跌倒概率”。模型更新后分数和阈值可能变化。
- 非跌倒时 `event` 为 `null`。疑似跌倒会创建事件，App 保存其 `id` 用于查询和确认。
- `created_at`、`deadline` 是 Unix 时间戳，单位秒；JavaScript 的毫秒时间需转换。
- `/api/info.metrics` 是五折按人划分验证的汇总，不是当前用户统计，也不是单个模型在全部记录上的独立成绩。

## 5. 事件确认与超时

App 收到事件后，每秒调用一次 `GET /api/events/{id}`，终态后停止轮询。查询和确认接口直接返回事件对象，其字段与推理响应的 `event` 一致。

确认安全：`POST /api/events/{id}/confirm`，JSON 为 `{"choice":"safe"}`。

请求帮助：同一路径，JSON 为 `{"choice":"help"}`。

| 状态 | 含义 | App 建议文案 |
|---|---|---|
| `pending` | 等待用户确认 | 是否需要帮助？ |
| `safe` | 用户确认安全 | 已确认安全 |
| `help_requested` | 用户主动求助 | 已生成模拟通知 |
| `simulated_notification` | 超过确认截止时间 | 已超时，已生成模拟通知 |

`reason` 在等待时为 `null`，用户确认后为 `user_confirmation`，超时后为 `confirmation_timeout`。确认时限当前为 20 秒，从 `/api/info.confirm_seconds` 获取；具体事件以 `deadline` 为准，是否超时最终由服务端决定。

终态不能改写；重复提交同一已成功确认返回原状态，提交相反选项返回 409。收到 409 后重新查询事件，更新页面，不要覆盖服务器状态。已超时后再确认也返回 409。

超时只在查询或确认请求时更新，没有后台通知任务；关闭 App 不会触发真实短信或推送。事件只存在单进程内存中，最多 512 条、有效期 1 小时，重启后清空，容量满时可能提前淘汰旧事件。部署仅支持 **一个 worker、一个实例**。

`/predict` 没有幂等键，重复提交同一段记录可能产生多个事件。App 应避免重复点击和无条件自动重试；网络中断后不要声称服务端一定没有接收。当前没有按用户、设备或请求 ID 查询历史的接口。

## 6. 错误处理

现有接口错误响应使用 `{"detail":"错误说明"}`。App 先检查 HTTP 状态，再解析响应；代理层错误或断网也需单独处理。

| 状态码 | 处理建议 |
|---|---|
| 401 | 检查访问口令 |
| 404 | 样例不存在，或事件过期、被淘汰、服务重启；结束该事件轮询 |
| 409 | 事件已处理或超时；重新查询状态 |
| 413 | 请求超过 2 MB |
| 422 | 字段、数值、行数、单位相关质量或时长不符合要求；展示 detail 并检查采样数据 |
| 503 / 其他 5xx | 服务繁忙、代理或服务器错误；提示失败，避免反复提交制造重复事件 |

当前无用户/设备账号体系、独立 SOS 创建接口、历史数据库、WebSocket 或真实推送。`help` 确认必须关联已存在的疑似跌倒事件；独立 SOS 按键业务需要双方另行设计。

## 7. 无硬件联调示例

先启动服务，再在任意目录执行下面的 Python 代码。它从服务端取一条完整公开样例进行推理，不创建文件；若设置了口令，在客户端进程环境中提供同名 `DEMO_ACCESS_TOKEN`。

```python
import json
import os
from urllib.request import Request, urlopen

base = "http://127.0.0.1:8000"  # 真机或远程环境改为可达的服务地址
headers = {"Content-Type": "application/json"}
token = os.environ.get("DEMO_ACCESS_TOKEN")
if token:
    headers["Authorization"] = "Bearer " + token

def call(path, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    with urlopen(Request(base + path, data=data, headers=headers), timeout=30) as r:
        return json.load(r)

record = call("/api/samples/fall")
result = call("/api/predict", {"samples": record["samples"]})
print(result)
if result["event"]:
    event_id = result["event"]["id"]
    print(call(f"/api/events/{event_id}/confirm", {"choice": "safe"}))
```

第一轮联调完成标准：四条样例均可上传并显示结果；疑似跌倒可确认安全、求助和超时；错误口令、错误数据、过期事件有明确提示。随后再对齐 App 的 BLE 采样与单位转换。
