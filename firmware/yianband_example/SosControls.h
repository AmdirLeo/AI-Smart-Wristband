#pragma once
#include "ButtonInput.h"

enum class SosAction { none, trigger, cancel };

// Short release triggers; hold >=1.5s cancels. No dead zone in between:
// any release that did not escalate to a cancel counts as a tap, so a
// 1.0-1.5 s press is no longer silently dropped.
// Button state survives BLE transitions so a held key cannot become a new tap.
struct SosControls {
  ButtonInput sos, cancel;
  bool suppressTap = false;

  SosAction update(bool sosPressed, bool cancelPressed, uint32_t now) {
    const bool wasDown = sos.down;
    const bool held = sos.update(sosPressed, now, 1500);
    const bool cancelled = cancel.update(cancelPressed, now, 0);
    if (sos.down && !wasDown) suppressTap = false;
    if (cancelPressed || cancel.down || cancelled || held) suppressTap = true;
    const bool released = wasDown && !sos.down;
    const bool tap = released && !suppressTap && !sos.fired;
    if (cancelled || held) return SosAction::cancel;
    return tap ? SosAction::trigger : SosAction::none;
  }
};
