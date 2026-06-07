#include "Capture/Zoom/zoom_hysteresis.h"

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

// Thresholds (mirrored from zoom_easing_constants.h): in 0.2s, out 0.3s,
// min-on 0.30s.

TEST(ZoomHysteresisTest, RequiresSustainedWantedToActivate) {
  ZoomHysteresis h;
  EXPECT_FALSE(h.Update(0.0, true));   // just became wanted
  EXPECT_FALSE(h.Update(0.1, true));   // 0.1s < 0.2s in-delay
  EXPECT_TRUE(h.Update(0.2, true));    // 0.2s reached → ON
}

TEST(ZoomHysteresisTest, SingleFrameFlickerNeverActivates) {
  ZoomHysteresis h;
  EXPECT_FALSE(h.Update(0.0, true));
  EXPECT_FALSE(h.Update(0.01, false));  // wanted dropped before the in-delay
  EXPECT_FALSE(h.Update(0.5, false));
}

TEST(ZoomHysteresisTest, StaysOnThroughMinOnAndOutDelay) {
  ZoomHysteresis h;
  h.Update(0.0, true);
  ASSERT_TRUE(h.Update(0.2, true));     // ON at t=0.2
  // wanted goes false at 0.3; must stay on until BOTH out-delay (0.3s) and
  // min-on (0.3s from turn-on at 0.2) are satisfied.
  EXPECT_TRUE(h.Update(0.3, false));    // out-delay just started
  EXPECT_TRUE(h.Update(0.5, false));    // 0.2s into out-delay (< 0.3)
  EXPECT_FALSE(h.Update(0.6, false));   // 0.3s out-delay + min-on satisfied → OFF
}

TEST(ZoomHysteresisTest, ResetClearsState) {
  ZoomHysteresis h;
  h.Update(0.0, true);
  ASSERT_TRUE(h.Update(0.2, true));
  h.Reset();
  EXPECT_FALSE(h.stable_zoom_active());
  // After reset, activation requires the full in-delay again. (Use 1.0 → 1.3
  // rather than 1.2: 1.2 - 1.0 is 0.199999… in double, just under the 0.2
  // in-delay — a hand-picked-timestamp FP artifact, not a code edge.)
  EXPECT_FALSE(h.Update(1.0, true));
  EXPECT_TRUE(h.Update(1.3, true));
}

}  // namespace
}  // namespace clingfy::capture
