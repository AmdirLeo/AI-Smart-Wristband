#include "../yianband_example/ButtonInput.h"
#include <assert.h>
int main() {
  ButtonInput sos;
  assert(!sos.update(true, 100, 1500));
  assert(!sos.update(false, 110, 1500)); // bounce
  assert(!sos.update(true, 120, 1500));
  assert(!sos.update(true, 150, 1500));
  assert(!sos.update(true, 1649, 1500));
  assert(sos.update(true, 1650, 1500));
  for (uint32_t t = 1700; t < 10000; t += 50) assert(!sos.update(true, t, 1500));
  assert(!sos.update(false, 10000, 1500));
  assert(!sos.update(false, 10030, 1500));
  assert(!sos.update(true, 10100, 1500));
  assert(!sos.update(true, 10130, 1500));
  assert(sos.update(true, 11630, 1500));

  ButtonInput cancel;
  assert(!cancel.update(true, 0, 0));
  assert(!cancel.update(true, 29, 0));
  assert(cancel.update(true, 30, 0));
  assert(!cancel.update(true, 1000, 0));
  // Unsigned elapsed calculation remains valid across millis rollover.
  ButtonInput wrap;
  assert(!wrap.update(true, UINT32_MAX - 100, 1500));
  assert(!wrap.update(true, UINT32_MAX - 70, 1500));
  assert(wrap.update(true, 1429, 1500));
}
