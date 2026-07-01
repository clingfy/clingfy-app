#include "Capture/Cursor/cursor_export_renderer.h"

#include <gtest/gtest.h>

// Pure click-ripple timing. The D2D drawing (DrawClicks / Draw) is exercised by
// the export_pipeline round-trip tests on a real device; here we pin the timing
// logic deterministically.
namespace clingfy::capture {
namespace {

constexpr std::int64_t kRipple = 450;

TEST(ClickRippleProgressTest, InactiveBeforeAndAfterWindow) {
  EXPECT_LT(ClickRippleProgress(1000, 900, kRipple), 0.0);   // before the click
  EXPECT_LT(ClickRippleProgress(1000, 1500, kRipple), 0.0);  // past ripple end
}

TEST(ClickRippleProgressTest, ProgressZeroToOneAcrossWindow) {
  EXPECT_DOUBLE_EQ(ClickRippleProgress(1000, 1000, kRipple), 0.0);  // at click
  EXPECT_NEAR(ClickRippleProgress(1000, 1000 + kRipple / 2, kRipple), 0.5, 0.01);
  EXPECT_DOUBLE_EQ(ClickRippleProgress(1000, 1000 + kRipple, kRipple), 1.0);
}

TEST(ClickRippleProgressTest, ZeroOrNegativeRippleIsInactive) {
  EXPECT_LT(ClickRippleProgress(1000, 1000, 0), 0.0);
}

}  // namespace
}  // namespace clingfy::capture
