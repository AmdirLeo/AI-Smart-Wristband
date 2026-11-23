#pragma once
#include <stddef.h>
#include <string.h>

enum class BandCommand { none, sosOn, sosOff, mute };

// The app sends newline-delimited JSON; UART callbacks may split/combine frames.
// Only these small, whitespace-insensitive control frames are accepted.
struct BandCommands {
  char line[64] = {};
  size_t used = 0;
  bool overflow = false;

  void reset() { used = 0; overflow = false; }

  BandCommand push(char c) {
    if (c != '\n') {
      if (c == ' ' || c == '\t' || c == '\r') return BandCommand::none;
      if (used + 1 < sizeof(line)) line[used++] = c;
      else overflow = true;
      return BandCommand::none;
    }
    line[used] = 0;
    BandCommand result = BandCommand::none;
    if (!overflow) {
      if (!strcmp(line, "{\"t\":\"sos-on\"}")) result = BandCommand::sosOn;
      else if (!strcmp(line, "{\"t\":\"sos-off\"}")) result = BandCommand::sosOff;
      else if (!strcmp(line, "{\"t\":\"mute\"}")) result = BandCommand::mute;
    }
    reset();
    return result;
  }
};
