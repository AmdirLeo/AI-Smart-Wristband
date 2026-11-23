#pragma once
#include <Arduino.h>
#include <math.h>

// HR8833: D1 -> IA1, D2 -> IA2; motor -> MA1/MA2.
// MAX98357A: D8 -> BCLK, D9 -> LRC, D10 -> DIN, D3 -> SD.
// Both modules use 3.3 V for this test; all grounds must be common.
// Connect speaker only between SPK+ and SPK-, never to GND.
namespace LocalFeedback {
constexpr uint8_t motorPwm = D1, motorDirection = D2;
constexpr uint8_t ampEnable = D3, bclk = D8, lrclk = D9, data = D10;
constexpr uint8_t motorDuty = 200; // ~78%, for the specified 3 V motor on 3.3 V VM
// 31.25 kHz, 16-bit stereo; repeating 32-frame sine = 976.56 Hz.
// EasyDMA reads RAM; never modify this buffer while I2S is enabled.
alignas(4) static uint32_t tone[32];
static bool audioRunning = false, useAudio = false, useMotor = false;
static bool active = false, outputOn = false;
static uint32_t startedAt = 0, duration = 0;
static volatile uint32_t dmaBlocks = 0;

inline void audioStart() {
  NRF_I2S->ENABLE = 0;
  NRF_I2S->CONFIG.MODE = I2S_CONFIG_MODE_MODE_Master;
  NRF_I2S->CONFIG.RXEN = 0;
  NRF_I2S->CONFIG.TXEN = 1;
  NRF_I2S->CONFIG.MCKEN = 1;
  NRF_I2S->CONFIG.MCKFREQ = I2S_CONFIG_MCKFREQ_MCKFREQ_32MDIV32;
  NRF_I2S->CONFIG.RATIO = I2S_CONFIG_RATIO_RATIO_32X;
  NRF_I2S->CONFIG.SWIDTH = I2S_CONFIG_SWIDTH_SWIDTH_16Bit;
  NRF_I2S->CONFIG.ALIGN = I2S_CONFIG_ALIGN_ALIGN_Left;
  NRF_I2S->CONFIG.FORMAT = I2S_CONFIG_FORMAT_FORMAT_I2S;
  NRF_I2S->CONFIG.CHANNELS = I2S_CONFIG_CHANNELS_CHANNELS_Stereo;
  NRF_I2S->PSEL.MCK = 0xFFFFFFFF;
  NRF_I2S->PSEL.SCK = g_ADigitalPinMap[bclk];
  NRF_I2S->PSEL.LRCK = g_ADigitalPinMap[lrclk];
  NRF_I2S->PSEL.SDOUT = g_ADigitalPinMap[data];
  NRF_I2S->PSEL.SDIN = 0xFFFFFFFF;
  NRF_I2S->RXTXD.MAXCNT = 32;
  NRF_I2S->TXD.PTR = (uint32_t)tone;
  NRF_I2S->EVENTS_TXPTRUPD = 0;
  NRF_I2S->EVENTS_STOPPED = 0;
  dmaBlocks = 0;
  NVIC_ClearPendingIRQ(I2S_IRQn);
  NVIC_SetPriority(I2S_IRQn, 6); // leave SoftDevice radio interrupts higher priority
  NRF_I2S->INTENSET = I2S_INTENSET_TXPTRUPD_Msk;
  NVIC_EnableIRQ(I2S_IRQn);
  NRF_I2S->ENABLE = 1;
  NRF_I2S->TASKS_START = 1;
  audioRunning = true;
}

inline void stop() {
  digitalWrite(ampEnable, LOW);
  analogWrite(motorPwm, 0);
  digitalWrite(motorDirection, LOW);
  if (audioRunning) {
    NRF_I2S->INTENCLR = 0xFFFFFFFF;
    NVIC_DisableIRQ(I2S_IRQn);
    NRF_I2S->EVENTS_STOPPED = 0;
    NRF_I2S->TASKS_STOP = 1;
    const uint32_t began = micros();
    while (!NRF_I2S->EVENTS_STOPPED && uint32_t(micros() - began) < 2000) {}
    NRF_I2S->ENABLE = 0;
    NVIC_ClearPendingIRQ(I2S_IRQn);
    audioRunning = false;
    if (Serial) { Serial.print("audio stopped dma_blocks="); Serial.println(dmaBlocks); }
  }
  active = outputOn = false;
}

inline void begin() {
  digitalWrite(ampEnable, LOW);
  pinMode(ampEnable, OUTPUT);
  digitalWrite(motorDirection, LOW);
  pinMode(motorDirection, OUTPUT);
  digitalWrite(motorPwm, LOW);
  pinMode(motorPwm, OUTPUT);
  analogWriteResolution(8);
  const uint8_t audioPins[] = {bclk, lrclk, data};
  for (uint8_t pin : audioPins) {
    digitalWrite(pin, LOW);
    pinMode(pin, OUTPUT);
  }
  for (unsigned i = 0; i < 32; ++i) {
    int16_t sample = (int16_t)(1200.0f * sinf(6.2831853f * i / 32));
    tone[i] = uint16_t(sample) | (uint32_t(uint16_t(sample)) << 16);
  }
  stop();
}

inline void start(bool audio, bool motor, uint32_t milliseconds) {
  stop();
  useAudio = audio;
  useMotor = motor;
  duration = milliseconds;
  startedAt = millis();
  if (audio) audioStart();
  active = true;
  if (Serial) {
    Serial.print("feedback audio="); Serial.print(audio);
    Serial.print(" motor="); Serial.print(motor);
    Serial.print(" duration_ms="); Serial.println(milliseconds);
  }
}

inline void tick() {
  if (!active) return;
  const uint32_t elapsed = millis() - startedAt;
  if (elapsed >= duration) { stop(); return; }
  const bool on = elapsed % 400 < 200;
  if (on == outputOn) return;
  outputOn = on;
  digitalWrite(ampEnable, useAudio && on ? HIGH : LOW);
  analogWrite(motorPwm, useMotor && on ? motorDuty : 0);
}
} // namespace LocalFeedback

extern "C" void I2S_IRQHandler(void) {
  if (NRF_I2S->EVENTS_TXPTRUPD) {
    NRF_I2S->EVENTS_TXPTRUPD = 0;
    NRF_I2S->TXD.PTR = (uint32_t)LocalFeedback::tone;
    ++LocalFeedback::dmaBlocks;
  }
  __DSB();
}
