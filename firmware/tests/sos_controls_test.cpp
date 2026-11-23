#include "../yianband_example/SosControls.h"
#include "../yianband_example/BandCommands.h"
#include <assert.h>
#include <initializer_list>

int main() {
  SosControls tap;
  assert(tap.update(true, false, 0) == SosAction::none);
  assert(tap.update(false, false, 10) == SosAction::none); // bounce
  assert(tap.update(true, false, 20) == SosAction::none);
  assert(tap.update(true, false, 50) == SosAction::none);
  assert(tap.update(false, false, 100) == SosAction::none);
  assert(tap.update(false, false, 130) == SosAction::trigger);
  assert(tap.update(false, false, 200) == SosAction::none);

  // No dead zone: any release that did not escalate to a cancel triggers,
  // so 1.0-1.5 s presses (previously silently dropped) now send SOS too.
  for (uint32_t duration : {999u, 1000u, 1499u}) {
    SosControls boundary;
    boundary.update(true, false, 0);
    boundary.update(true, false, 30);
    boundary.update(false, false, duration);
    assert(boundary.update(false, false, duration + 30) == SosAction::trigger);
  }
  SosControls hold;
  hold.update(true, false, 0);
  hold.update(true, false, 30);
  assert(hold.update(true, false, 1529) == SosAction::none);
  assert(hold.update(true, false, 1530) == SosAction::cancel);
  assert(hold.update(true, false, 1600) == SosAction::none);
  hold.update(false, false, 1700);
  assert(hold.update(false, false, 1730) == SosAction::none);

  // A cancel during a press must suppress its later release-triggered SOS.
  SosControls both;
  both.update(true, false, 0);
  both.update(true, false, 30);
  both.update(true, true, 50);
  assert(both.update(true, true, 80) == SosAction::cancel);
  both.update(true, false, 100);
  both.update(true, false, 130);
  both.update(false, false, 150);
  assert(both.update(false, false, 180) == SosAction::none);
  both.update(true, false, 200);
  both.update(true, false, 230);
  both.update(false, false, 250);
  assert(both.update(false, false, 280) == SosAction::trigger);

  SosControls wrap;
  wrap.update(true, false, UINT32_MAX - 100);
  wrap.update(true, false, UINT32_MAX - 70);
  assert(wrap.update(true, false, 1429) == SosAction::cancel);

  BandCommands parser;
  for (char c : "{\"t\":\"sos-") if (c) assert(parser.push(c) == BandCommand::none);
  for (char c : "on\"}") if (c) assert(parser.push(c) == BandCommand::none);
  assert(parser.push('\n') == BandCommand::sosOn);
  unsigned off = 0, mute = 0;
  for (char c : "{ \"t\" : \"sos-off\" }\r\n{\"t\":\"mute\"}\n") {
    if (!c) break;
    const auto cmd = parser.push(c);
    off += cmd == BandCommand::sosOff;
    mute += cmd == BandCommand::mute;
  }
  assert(off == 1 && mute == 1);
  for (unsigned i = 0; i < 80; ++i) parser.push('x');
  for (char c : "{\"t\":\"sos-on\"}\n") if (c) assert(parser.push(c) == BandCommand::none);
  for (char c : "{\"t\":\"sos-") if (c) parser.push(c);
  parser.reset(); // disconnect cannot leave a prefix for the next connection
  for (char c : "on\"}\n") if (c) assert(parser.push(c) == BandCommand::none);
}
