# 手环 ↔ 手机 App BLE 通信协议 v0.1

手环主控为 **XIAO nRF52840 Sense Plus**（板载 LSM6DS3TR-C 六轴 IMU），通过 BLE 把数据发给老人随身手机上的 Flutter App，App 再经 HTTP 中转到云端。

## 1. BLE 服务与特征（Nordic UART Service，NUS）

nRF52840 生态的事实标准，调试工具（nRF Connect、LightBlue）都直接支持。

| 项目 | UUID | 方向 | 说明 |
|---|---|---|---|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | — | NUS 服务 |
| TX 特征 | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | 手环 → 手机 | Notify |
| RX 特征 | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | 手机 → 手环 | Write（无响应即可） |

- 广播名：**`YianBand`**（App 按名字过滤扫描结果）
- App 连接后请求 **MTU ≥ 131**（Android 调 `requestMtu`）。
- 数据格式：**UTF-8 JSON，每帧以 `\n` 结尾**。一帧可能被拆到多个 Notify 包里，App 端按字节流累积、遇 `\n` 切帧（`band_protocol.dart` 已实现），固件端一帧一次 `notify` 发完即可。

## 2. 帧定义

### 2.1 手环 → 手机

**六轴原始帧 `raw`**（每 50ms 一帧 @20Hz，跌倒识别的模型输入，对齐 docs/API.md §3）

```json
{"t":"raw","s":[10.123,0.0102,0.0231,1.0032,1.234,-2.345,0.456]}
```

`"s"` 数组固定 7 个元素，列序与 model_service 推理输入一致：

| 序号 | 字段 | 单位 | 说明 |
|---|---|---|---|
| 0 | `timestamp_s` | 秒 | 同一记录内时间戳，自开机起累计 |
| 1–3 | `ax_g, ay_g, az_g` | g | 三轴加速度，保留重力 |
| 4–6 | `gx_dps, gy_dps, gz_dps` | °/s | 三轴角速度 |

App 将 raw 帧缓冲成 10–20 秒窗口（自动滚动保留最近约 19 秒），用户点「运行跌倒识别」
或疑似跌倒触发时调用 `POST /api/predict`。采样率必须 ≥14Hz，**不得用全零数组代替陀螺仪**。

**状态帧 `st`**（每 2 秒一帧，实时页展示）

```json
{"t":"st","g":1.02,"p":3.2,"r":-4.0,"s":0,"b":87,"q":123}
```

| 字段 | 含义 | 单位/取值 |
|---|---|---|
| `g`  | 合加速度模（√(ax²+ay²+az²)） | g |
| `p`  | 俯仰角 pitch | 度 |
| `r`  | 横滚角 roll | 度 |
| `s`  | 是否持续静止（端侧判断） | 0/1 |
| `b`  | 电量 | 0–100 |
| `q`  | 帧序号 | 递增整数 |

**事件帧 `ev`**（端侧初筛触发时立即发送）

```json
{"t":"ev","k":"fall","i":3.2,"w":12.0,"c":0.88,"q":124}
```

| 字段 | 含义 |
|---|---|
| `k` | 事件类型：`fall` 疑似跌倒 / `sos` 长按 SOS / `lowbat` 低电量 / `cancel` 老人按键确认没事 |
| `i` | 冲击峰值 g（fall 时有效） |
| `w` | 冲击后静止秒数（fall 时有效） |
| `c` | 端侧初筛选信度 0–1 |
| `q` | 帧序号 |

**确认帧 `ok`**：`{"t":"ok","q":123}` —— 手机确认收到事件帧（可选）。

### 2.2 手机 → 手环

| 帧 | 含义 |
|---|---|
| `{"t":"mute"}` | 静音当前语音/震动提示 |
| `{"t":"ok","q":n}` | 事件帧回执 |
| `{"t":"ask"}` | 请手环播放/触发“您还好吗”语音询问（原型阶段由手机 TTS 播放，此帧预留） |

## 3. 跌倒事件流程（对应 PPT 核心流程页）

```
手环端初筛(冲击>2.8g 且冲击后静止≥5s)
   → ev{fall} + 手环倒计时10s(语音询问+震动)
   → App 弹确认窗(TTS 语音询问, 10s 倒计时)
       ├─ 老人按“我没事”/语音确认 → ev{cancel} → App 调 POST /events/{id}/cancel，事件记录为误报
       └─ 超时无响应 / 点“立即求助” → App 调 PATCH /events/{id} {status:"open"}
            → 云端通知主要联系人；60s 未处理自动通知备用联系人
```

App 收到 `ev{fall}` 后立刻 `POST /api/v1/events {kind:"fall", status:"pending", ...}` 建事件；云端在 15 秒内未收到取消也会自动升级（双保险，适配 App 离线场景）。

## 4. 固件参考示例

见 `firmware/yianband_example/yianband_example.ino`（Arduino + Seeed nRF52 板包），
包含：NUS 服务搭建、IMU 采集打包、简单跌倒初筛规则、SOS/取消按键。烧录前需：

1. Arduino IDE 安装 Seeed nRF52 Boards 板包（见 Seeed Wiki "XIAO BLE" 教程）
2. 库管理器安装 `Seeed Arduino LSM6DS3`
3. `#define DEVICE_NAME "YianBand"` 可改成每位老人独立名字（如 `YianBand-01`）
