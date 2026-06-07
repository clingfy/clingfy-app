#include "Capture/Zoom/zoom_follow_smoother.h"

#include <gtest/gtest.h>

#include <cmath>

#include "preview/zoom_easing_constants.h"

namespace clingfy::capture {
namespace {

TEST(ZoomFollowSmootherTest, AlphaMatchesFormulaAtReferenceFps) {
  // normalizedFrames = (1/60)*60 = 1 → alpha = 1 - (1-0.15)^1 = 0.15.
  const double alpha = ZoomFollowAlpha(0.15, 1.0 / 60.0, 60.0);
  EXPECT_NEAR(alpha, 0.15, 1e-9);
}

TEST(ZoomFollowSmootherTest, AlphaParityWithPow) {
  // General parity with the documented formula for a non-trivial dt.
  const double strength = clingfy::preview::kZoomFollowStrengthDefault;
  const double dt = 1.0 / 30.0;  // 2 reference frames
  const double expected = 1.0 - std::pow(1.0 - strength, dt * 60.0);
  EXPECT_NEAR(ZoomFollowAlpha(strength, dt, 60.0), expected, 1e-9);
}

TEST(ZoomFollowSmootherTest, ClampsStrength) {
  EXPECT_DOUBLE_EQ(ClampFollowStrength(0.0),
                   clingfy::preview::kZoomFollowStrengthMin);
  EXPECT_DOUBLE_EQ(ClampFollowStrength(1.0),
                   clingfy::preview::kZoomFollowStrengthMax);
  EXPECT_DOUBLE_EQ(ClampFollowStrength(0.2), 0.2);
  // NaN → default.
  EXPECT_DOUBLE_EQ(ClampFollowStrength(std::nan("")),
                   clingfy::preview::kZoomFollowStrengthDefault);
}

TEST(ZoomFollowSmootherTest, ClampsDt) {
  EXPECT_DOUBLE_EQ(ClampFollowDtSeconds(0.0),
                   clingfy::preview::kZoomFollowMinDtSeconds);
  EXPECT_DOUBLE_EQ(ClampFollowDtSeconds(10.0),
                   clingfy::preview::kZoomFollowMaxDtSeconds);
}

TEST(ZoomFollowSmootherTest, LerpAndAlphaClamp) {
  EXPECT_DOUBLE_EQ(ZoomFollowLerp(0.0, 10.0, 0.5), 5.0);
  EXPECT_DOUBLE_EQ(ZoomFollowLerp(0.0, 10.0, -1.0), 0.0);  // alpha clamped to 0
  EXPECT_DOUBLE_EQ(ZoomFollowLerp(0.0, 10.0, 2.0), 10.0);  // alpha clamped to 1
}

TEST(ZoomFollowSmootherTest, RepeatedLerpConverges) {
  double cur = 1.0;
  const double alpha = ZoomFollowAlpha(0.15, 1.0 / 60.0, 60.0);
  for (int i = 0; i < 500; ++i) {
    cur = ZoomFollowLerp(cur, 2.0, alpha);
  }
  EXPECT_NEAR(cur, 2.0, 1e-3);
}

}  // namespace
}  // namespace clingfy::capture
