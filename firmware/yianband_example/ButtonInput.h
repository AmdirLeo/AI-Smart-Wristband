#pragma once
#include <stdint.h>

// 低有效按键：稳定 30ms 后确认边沿；每次按住仅产生一次事件。
struct ButtonInput {
  bool raw = false, down = false, fired = false;
  uint32_t changedAt = 0, pressedAt = 0;

  bool update(bool pressed, uint32_t now, uint32_t holdMs) {
    if (pressed != raw) {
      raw = pressed;
      changedAt = now;
    }
    if (raw != down && uint32_t(now - changedAt) >= 30) {
      down = raw;
      pressedAt = now;
      fired = false;
    }
    if (raw && down && !fired && uint32_t(now - pressedAt) >= holdMs) {
      fired = true;
      return true;
    }
    return false;
  }
};
