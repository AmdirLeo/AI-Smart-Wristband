#pragma once
#include "ButtonInput.h"

enum class SosAction { none, trigger, cancel };

// Keep the interaction thresholds: short release <1s; hold >=1.5s cancels.
// Button state survives BLE transitions so a held key cannot become a new tap.
struct SosControls {
  ButtonInput sos, cancel;
  bool suppressTap = false;

  SosAction update(bool sosPressed, bool cancelPressed, uint32_t now) {
    const bool wasDown = sos.down;
    const uint32_t pressedAt = sos.pressedAt;
    const bool held = sos.update(sosPressed, now, 1500);
    const bool cancelled = cancel.update(cancelPressed, now, 0);
    if (sos.down && !wasDown) suppressTap = false;
    if (cancelPressed || cancel.down || cancelled || held) suppressTap = true;
    const bool released = wasDown && !sos.down;
    const bool tap = released && !suppressTap && !sos.fired &&
                     uint32_t(now - pressedAt) < 1000;
    if (cancelled || held) return SosAction::cancel;
    return tap ? SosAction::trigger : SosAction::none;
  }
};
