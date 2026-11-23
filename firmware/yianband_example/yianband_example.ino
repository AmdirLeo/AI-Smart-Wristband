/*
 * 颐安云护 · 手环端参考固件（XIAO nRF52840 Sense Plus）
 * ------------------------------------------------
 * BLE 库：Bluefruit52Lib（Seeed/Adafruit nRF52 板包自带，BLEUart = Nordic UART Service）
 *
 * 功能：
 *   1. BLE(NUS) 按协议上报（docs/BLE通信协议.md / 仓库 docs/API.md）：
 *      - raw 帧 20Hz：[timestamp_s, ax_g, ay_g, az_g, gx_dps, gy_dps, gz_dps]
 *        —— App 缓冲 10–20 秒窗口后调用 model_service /api/predict 做跌倒识别
 *      - st 帧 0.5Hz：合加速度/姿态/静止/电量/屏幕诊断（实时页展示）
 *   2. 端侧跌倒初筛（冲击 + 持续静止 → ev{fall}，保留本地提示）
 *   3. D6 短按松开（<1s）SOS；D6 长按（≥1.5s）或 D7 取消
 *
 * 依赖（arduino-cli）：
 *   arduino-cli core install Seeeduino:nrf52
 *   arduino-cli lib install "Seeed Arduino LSM6DS3"
 *   arduino-cli lib install U8g2
 *   （Bluefruit52Lib 为板包自带，无需额外安装；不要用 ArduinoBLE，2.x 不支持该板包）
 *
 * 接线（原型洞洞板）：
 *   SOS 按键 -> D6（另一端 GND，INPUT_PULLUP）；取消按键 -> D7
 *   HR8833：IA1->D1、IA2->D2；马达接 MA1/MA2；VCC、VM 接 3V3，GND 共地
 *   MAX98357A：BCLK->D8、LRC->D9、DIN->D10、SD->D3；VIN->3V3，GND 共地
 *   8Ω/1W 扬声器接功放 SPK+/SPK-；GAIN 悬空，未用的 HR8833 IB1/IB2 接 GND
 *   I2C 屏幕：GND->GND，3V3->3V3，SCL->D5，SDA->D4（硬件 I2C；Sense Plus 的板载 IMU
 *             使用独立的 Wire1 总线；支持热插拔，拔插屏幕不影响运行）
 *             st 帧的 "scr" 字段为屏幕诊断：0 未检测到 / 1 检测到未初始化 / 2 已就绪
 *             当前使用 D4/D5 硬件 I2C 和全帧缓冲刷新。
 *   扬声器播放 I2S 提示音（非语音）；USB 115200 输入 a/v/t/x：声音/振动/两者/停止
 *   测试各持续 2 秒，无需 BLE；SOS 提示 1.2 秒，跌倒提示 10 秒，取消立即停止
 */

#include <bluefruit.h>
#include <U8g2lib.h>
#include <Wire.h>
#include <LSM6DS3.h>
#include <math.h>
#include "SosControls.h"
#include "BandCommands.h"
#include "LocalFeedback.h"

#define FIRMWARE_VERSION "io-20261123-2"

#define DEVICE_NAME   "YianBand"   // 可改为 YianBand-01 等区分不同老人
#define PIN_BTN_SOS   D6
#define PIN_BTN_CANCEL D7
#define PIN_LED_STAT  LED_RED      // 板载红灯（variant: LED_RED=11）

BLEUart bleuart;                   // Nordic UART Service（NUS）
LSM6DS3 imu(I2C_MODE, 0x6A);       // 板载 LSM6DS3TR-C

// —— I2C 状态屏（硬件 I2C，D4/D5；板载 IMU 使用独立 Wire1） ——
// 接线固定：SCL=D5，SDA=D4；地址自动尝试 0x3C（多数屏）与 0x3D
// 沿用当前 SH1106 驱动；若更换屏幕，应依据实际控制器选择对应类名。
// 使用全帧缓冲，才能配合 clearBuffer()/sendBuffer() 刷新完整 128x64 画面。
U8G2_SH1106_128X64_NONAME_F_HW_I2C *u8g2 = nullptr;
uint8_t scrAddr8 = 0x78;           // 探测到的 8 位地址（0x78=0x3C / 0x7A=0x3D）
int     scrState = 0;              // 0 未检测到 / 1 已检测未初始化 / 2 已就绪
bool     screenReady = false;      // 屏幕是否已初始化（断电/拔出后需重新 init）
#define SCREEN_FONT u8g2_font_wqy12_t_gb2312   // 中文 12px（GB2312 全集）
float    gNow = 1.0f;              // 供屏幕显示的最新合加速度
uint32_t lastScreenMs = 0;

// —— 上报节奏 ——
const uint32_t RAW_PERIOD_MS   = 50;    // 20 Hz 六轴（模型输入，≥14Hz 即可）
const uint32_t STATE_PERIOD_MS = 2000;  // 状态帧
uint32_t bootMs = 0, lastRawMs = 0, lastStateMs = 0;

// —— 端侧初筛参数（对应 PPT「端侧初筛」，阈值待实测标定） ——
const float IMPACT_G   = 2.8f;   // 冲击阈值
const float STILL_DEV  = 0.12f;  // 静止判定：|g|-1 偏差
const uint32_t STILL_MS = 5000;  // 冲击后持续静止时长
const uint32_t COUNTDOWN_S = 10; // 本地确认倒计时
float    gPeak = 0;
bool     inImpact = false;
uint32_t impactMs = 0, stillSinceMs = 0;
uint16_t seq = 0;
int      batteryPct = 90;
bool     countdownActive = false;
uint32_t countdownEndMs = 0;
SosControls buttons;
BandCommands commands;
bool sosAlerting = false;
uint32_t sosNoticeUntil = 0;


// 分片发送：BLEUart 内部 FIFO 一次只接受约 MTU-3 字节（默认 MTU=23 时仅 20），
// 超长帧的剩余部分会被直接丢弃 → 必须分片 + 背压重试。
void sendFrame(const char* json) {
  int len = strlen(json);
  int off = 0;
  const uint32_t started = millis();
  while (off < len) {
    if (!Bluefruit.connected() || millis() - started > 250) return;
    int n = len - off;
    if (n > 20) n = 20;   // MTU=23 时单包上限 20 字节（保守值，协商大 MTU 后同样可用）
    size_t w = bleuart.write((const uint8_t*)json + off, n);
    if (w == 0) {
      delay(1);           // FIFO 满，等待排空后重试
      continue;
    }
    off += w;
  }
}

void sendEvent(const char* kind, float impact, float stillSec, float conf) {
  char buf[96];
  snprintf(buf, sizeof(buf),
           "{\"t\":\"ev\",\"k\":\"%s\",\"i\":%.2f,\"w\":%.1f,\"c\":%.2f,\"q\":%u}\n",
           kind, impact, stillSec, conf, seq++);
  sendFrame(buf);
  if (Serial) Serial.print(buf); // USB 可核对按键是否产生了事件
}

void sendState(float g, float pitch, float roll, bool still) {
  char buf[110];
  snprintf(buf, sizeof(buf),
           "{\"t\":\"st\",\"g\":%.2f,\"p\":%.1f,\"r\":%.1f,\"s\":%d,\"b\":%d,\"scr\":%d,\"q\":%u}\n",
           g, pitch, roll, still ? 1 : 0, batteryPct, scrState, seq++);
  sendFrame(buf);
}

void sendRaw(uint32_t now, float ax, float ay, float az,
             float gx, float gy, float gz) {
  char buf[80];
  float ts = (now - bootMs) / 1000.0f;  // 记录内时间戳（秒，自连接起）
  snprintf(buf, sizeof(buf),
           "{\"t\":\"raw\",\"s\":[%.2f,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f]}\n",
           ts, ax, ay, az, gx, gy, gz);
  sendFrame(buf);
}

// 下行指令与本地按键都由主循环处理，避免 BLE 回调与 I2S/PWM 竞争。
void startSosAlert() {
  sosAlerting = true;
  countdownActive = false;
  inImpact = false;
  LocalFeedback::start(true, true, 1200);
}

void cancelAlert(bool notifyApp) {
  LocalFeedback::stop();
  sosAlerting = false;
  countdownActive = false;
  inImpact = false;
  gPeak = 0;
  stillSinceMs = 0;
  sosNoticeUntil = 0;
  if (notifyApp && Bluefruit.connected()) sendEvent("cancel", 0, 0, 1.0f);
}

void commandTask() {
  while (bleuart.available()) {
    switch (commands.push((char)bleuart.read())) {
      case BandCommand::sosOn: startSosAlert(); break;
      case BandCommand::sosOff: cancelAlert(false); break;
      case BandCommand::mute:
        LocalFeedback::stop();
        countdownActive = false;
        inImpact = false;
        break;
      default: break;
    }
  }
}

void buttonTask(uint32_t now, bool connected) {
  static bool sosRaw = false;
  const bool sosPressed = digitalRead(PIN_BTN_SOS) == LOW;
  const bool cancelPressed = digitalRead(PIN_BTN_CANCEL) == LOW;
  if (sosPressed != sosRaw) {   // 边沿日志：连极短的点按也能在串口看到
    sosRaw = sosPressed;
    if (Serial) { Serial.print("[btn] D6 "); Serial.println(sosPressed ? "down" : "up"); }
  }
  const SosAction action = buttons.update(sosPressed, cancelPressed, now);
  if (action == SosAction::cancel) {
    if (Serial) Serial.println("[btn] hold/cancel -> cancel");
    cancelAlert(true);
  } else if (action == SosAction::trigger) {
    if (!connected) {           // 断连：不补发事件，手环也不本地告警
      if (Serial) Serial.println("[btn] tap ignored (not connected)");
      return;
    }
    if (Serial) Serial.println("[btn] tap -> sos sent");
    startSosAlert();
    sendEvent("sos", 0, 0, 1.0f);
    sosNoticeUntil = now + 3000;
  }
}

float readG(float ax, float ay, float az) { return sqrtf(ax*ax + ay*ay + az*az); }

int readBattery() {  // XIAO Sense Plus 的 VBAT 分压（ADC_BAT），按电池 3.55~4.2V 映射
  // VBAT_ENABLE 为低电平时接通板载电池分压器；读取后关闭以减少耗电。
  digitalWrite(VBAT_ENABLE, LOW);
  delay(2);
  int raw = analogRead(ADC_BAT);
  digitalWrite(VBAT_ENABLE, HIGH);
  float v = raw / 4095.0f * 3.3f * 2.0f;  // 12 位 ADC，板载 1/2 分压
  int pct = (int)((v - 3.55f) / (4.2f - 3.55f) * 100);
  return constrain(pct, 0, 100);
}

// 屏幕在位探测：硬件 I2C 上对地址发一次传输，NACK/错误 = 不在位
bool screenPresent(uint8_t addr8) {
  Wire.beginTransmission(addr8 >> 1);   // 0x78>>1 = 0x3C
  return Wire.endTransmission() == 0;
}

// 初始化/重新初始化屏幕（重插或断电恢复后调用）
void screenInit() {
  u8g2->setI2CAddress(scrAddr8);
  u8g2->begin();
  u8g2->enableUTF8Print();
  u8g2->setFont(SCREEN_FONT);
  screenReady = true;
  scrState = 2;
}

// —— 屏幕：500ms 节流刷新，显示蓝牙/电量/状态/事件提示 ——
void drawScreen() {
  char line[40];
  u8g2->clearBuffer();
  u8g2->setFont(SCREEN_FONT);
  if (batteryPct > 0) snprintf(line, sizeof(line), "颐安云护  电量%d%%", batteryPct);
  else                snprintf(line, sizeof(line), "颐安云护  USB供电");
  u8g2->drawUTF8(0, 12, line);
  u8g2->drawLine(0, 15, 127, 15);
  if (Bluefruit.connected()) {
    u8g2->drawUTF8(0, 29, "蓝牙:已连接");
    snprintf(line, sizeof(line), "状态:%s  g=%.2f",
             fabsf(gNow - 1.0f) < STILL_DEV ? "静止" : "活动", gNow);
    u8g2->drawUTF8(0, 43, line);
  } else {
    u8g2->drawUTF8(0, 29, "蓝牙:未连接");
    u8g2->drawUTF8(0, 43, "等待手机连接...");
  }
  if (sosAlerting) {
    u8g2->drawUTF8(0, 60, "SOS告警中 长按取消");
  } else if ((int32_t)(sosNoticeUntil - millis()) > 0) {
    u8g2->drawUTF8(0, 60, "SOS已触发");
  } else if (countdownActive) {
    int left = (int32_t)(countdownEndMs - millis()) / 1000 + 1;
    if (left < 0) left = 0;
    snprintf(line, sizeof(line), "疑似跌倒! 倒计时%ds", left);
    u8g2->drawUTF8(0, 60, line);
  } else if (inImpact) {
    u8g2->drawUTF8(0, 60, "检测到冲击...");
  } else {
    u8g2->drawUTF8(0, 60, "运行正常");
  }
  u8g2->sendBuffer();
}

void screenTask() {
  uint32_t now = millis();
  if (now - lastScreenMs < 500) return;
  lastScreenMs = now;

  if (u8g2 == nullptr) {
    // 首次寻找屏幕：依次尝试两个常见地址
    const uint8_t addrs[2] = {0x78, 0x7A};   // 0x3C / 0x3D
    for (int a = 0; a < 2; a++) {
      if (screenPresent(addrs[a])) {
        scrAddr8 = addrs[a];
        u8g2 = new U8G2_SH1106_128X64_NONAME_F_HW_I2C(U8G2_R0, U8X8_PIN_NONE);
        screenInit();
        return;                              // 本周期先初始化，下周期再绘制
      }
    }
    scrState = 0;                            // 没找到：接线/电源/地址问题
    return;
  }

  // 已初始化：探测在位状态（拔出/断电 → 需重新初始化）
  if (!screenPresent(scrAddr8)) {
    scrState = 1;
    screenReady = false;
    return;
  }
  if (!screenReady) screenInit();            // 重新接入：重发初始化序列
  scrState = 2;
  if (!Bluefruit.connected()) batteryPct = readBattery();
  drawScreen();
}

// 仅连接 USB 串口监视器时输出；不阻塞电池供电或 BLE 通信。
void serialDiagnostics() {
  static uint32_t last = 0;
  if (!Serial || millis() - last < 1000) return;
  last = millis();
  Serial.print("fw=" FIRMWARE_VERSION " ble=");
  Serial.print(Bluefruit.connected() ? 1 : 0);
  Serial.print(" D6="); Serial.print(digitalRead(PIN_BTN_SOS));
  Serial.print(" D7="); Serial.print(digitalRead(PIN_BTN_CANCEL));
  Serial.print(" feedback="); Serial.print(LocalFeedback::active);
  Serial.print(" motor="); Serial.print(LocalFeedback::useMotor && LocalFeedback::outputOn);
  Serial.print(" amp="); Serial.print(digitalRead(LocalFeedback::ampEnable));
  Serial.print(" dma="); Serial.println(LocalFeedback::dmaBlocks);
}

// 单字符 USB 模块测试，不制造 SOS 事件或改变云端记录。
void feedbackTask() {
  if (Serial) {
    while (Serial.available()) {
      switch (Serial.read()) {
        case 'a': LocalFeedback::start(true, false, 2000); break;
        case 'v': LocalFeedback::start(false, true, 2000); break;
        case 't': LocalFeedback::start(true, true, 2000); break;
        case 'x': LocalFeedback::stop(); Serial.println("feedback stopped"); break;
        default: break;
      }
    }
  }
  LocalFeedback::tick();
  // XIAO 板载 LED 为低电平点亮，和本地提示同步。
  digitalWrite(PIN_LED_STAT, LocalFeedback::active && LocalFeedback::outputOn ? LOW : HIGH);
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_BTN_SOS, INPUT_PULLUP);
  pinMode(PIN_BTN_CANCEL, INPUT_PULLUP);
  LocalFeedback::begin();
  pinMode(PIN_LED_STAT, OUTPUT);
  digitalWrite(PIN_LED_STAT, HIGH);
  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, HIGH);
  analogReadResolution(12);

  if (imu.begin() != 0) { /* IMU 初始化失败：LED 常亮提示 */ }
  Wire.begin();                             // 硬件 I2C（D4=SDA, D5=SCL）

  Bluefruit.begin();
  Bluefruit.autoConnLed(false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName(DEVICE_NAME);

  bleuart.begin();
  // 主循环轮询 UART，保留分片帧直到换行。

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  // 注意：不加 addTxPower()，31 字节广播包才放得下完整名字（避免截断成 YianB）
  Bluefruit.Advertising.addService(bleuart);
  Bluefruit.Advertising.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);   // 先快后慢
  Bluefruit.Advertising.start();
}

void loop() {
  static bool wasConnected = false;
  const bool connected = Bluefruit.connected();
  const uint32_t now = millis();
  if (connected != wasConnected) {
    wasConnected = connected;
    commands.reset();
    buttons.suppressTap = true;
    if (connected) {
      bootMs = lastRawMs = lastStateMs = now;
    } else {
      countdownActive = false;
      inImpact = false;
      LocalFeedback::stop();
    }
  }
  if (connected) commandTask();
  else while (bleuart.available()) bleuart.read();
  buttonTask(now, connected); // 断连时仍可取消已有提示；离线短按不补发。
  feedbackTask();
  serialDiagnostics();
  screenTask();
  if (!connected) { delay(5); return; }

  // —— 20Hz 六轴采集 + raw 帧（模型识别输入） ——
  if (now - lastRawMs >= RAW_PERIOD_MS) {
    lastRawMs = now;
    float ax = imu.readFloatAccelX();
    float ay = imu.readFloatAccelY();
    float az = imu.readFloatAccelZ();
    float gx = imu.readFloatGyroX();
    float gy = imu.readFloatGyroY();
    float gz = imu.readFloatGyroZ();
    sendRaw(now, ax, ay, az, gx, gy, gz);

    // —— 端侧初筛：冲击 → 持续静止 ——
    float g = readG(ax, ay, az);
    gNow = g;
    bool still = fabsf(g - 1.0f) < STILL_DEV;
    if (!sosAlerting && !inImpact && g > IMPACT_G) { inImpact = true; gPeak = g; impactMs = now; }
    else if (inImpact && g > gPeak) gPeak = g;
    if (inImpact && still) {
      if (stillSinceMs == 0) stillSinceMs = now;
      if (now - impactMs > STILL_MS && !countdownActive) {
        float stillSec = (now - stillSinceMs) / 1000.0f;
        sendEvent("fall", gPeak, stillSec, 0.85f);   // 事件帧仍发，App 记录端侧初筛
        countdownActive = true;
        countdownEndMs = now + COUNTDOWN_S * 1000;
        LocalFeedback::start(true, true, COUNTDOWN_S * 1000);
      }
    } else {
      stillSinceMs = 0;
    }
    if (inImpact && now - impactMs > 30000) { inImpact = false; gPeak = 0; }

    if (countdownActive && (int32_t)(now - countdownEndMs) >= 0) {
      countdownActive = false;
      LocalFeedback::stop();
    }
  }

  // —— 0.5Hz 状态帧（实时页展示 + 电量） ——
  if (now - lastStateMs >= STATE_PERIOD_MS) {
    lastStateMs = now;
    batteryPct = readBattery();
    float ax = imu.readFloatAccelX();
    float ay = imu.readFloatAccelY();
    float az = imu.readFloatAccelZ();
    float g = readG(ax, ay, az);
    float pitch = atan2f(-ax, sqrtf(ay * ay + az * az)) * 57.2958f;
    float roll  = atan2f(ay, az) * 57.2958f;
    sendState(g, pitch, roll, fabsf(g - 1.0f) < STILL_DEV);
  }
}
