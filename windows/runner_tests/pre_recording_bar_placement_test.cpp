#include <gtest/gtest.h>

#include <array>

#include "Capture/PreRecordingBar/pre_recording_bar_model.h"

namespace clingfy::capture {
namespace {

// Real work areas from the two-monitor setup that surfaced the bug: a 1920x1080
// laptop panel at 125% scale (primary, logical 1536x864) with a larger external
// display placed to its right in virtual-desktop coordinates.
constexpr int kPrimaryL = 0;
constexpr int kPrimaryT = 0;
constexpr int kPrimaryR = 1536;
constexpr int kPrimaryB = 864;

constexpr int kSecondL = 1536;
constexpr int kSecondT = 0;
constexpr int kSecondR = 3584;
constexpr int kSecondB = 1152;

std::array<BarButtonSpec, kBarButtonCount> IdleSpecs() {
  PreRecordingBarInputs in;
  in.phase = 0;  // idle
  return ComputeBarButtons(in);
}

BarPlacement PlaceOnPrimary(double scale) {
  return ComputeBarPlacement(kPrimaryL, kPrimaryT, kPrimaryR, kPrimaryB, scale,
                             IdleSpecs());
}

TEST(PreRecordingBarPlacementTest, CentersHorizontallyOnTheGivenWorkArea) {
  const BarPlacement p = PlaceOnPrimary(1.0);
  const int center = p.x + p.width / 2;
  // Allow a pixel of integer-division slack.
  EXPECT_NEAR(center, (kPrimaryL + kPrimaryR) / 2, 1);
}

TEST(PreRecordingBarPlacementTest, SitsAboveTheBottomEdgeByTheInset) {
  const BarPlacement p = PlaceOnPrimary(1.0);
  EXPECT_EQ(p.y + p.height + kBarBottomInset, kPrimaryB);
}

// The regression this file exists for. The bar used to resolve its monitor from
// its own window, which is created at (0, 0) and so always answered "primary".
// A user working on the second display saw nothing: the bar was alive, visible,
// and correctly painted -- on the other screen. Placement must follow whichever
// work area it is handed.
TEST(PreRecordingBarPlacementTest, SecondaryWorkAreaKeepsTheBarOnThatMonitor) {
  const BarPlacement p = ComputeBarPlacement(kSecondL, kSecondT, kSecondR,
                                             kSecondB, 1.0, IdleSpecs());

  EXPECT_GE(p.x, kSecondL) << "bar spilled left of the secondary monitor";
  EXPECT_LE(p.x + p.width, kSecondR)
      << "bar spilled right of the secondary monitor";
  EXPECT_GE(p.y, kSecondT);
  EXPECT_LE(p.y + p.height, kSecondB);

  // Explicitly NOT on the primary display.
  EXPECT_FALSE(p.x < kPrimaryR)
      << "bar landed on the primary monitor instead of the anchor monitor";
}

// A display positioned to the LEFT of the primary has negative virtual-desktop
// coordinates; the bar must follow it there rather than clamping to zero.
TEST(PreRecordingBarPlacementTest, NegativeOriginMonitorIsHonored) {
  const BarPlacement p = ComputeBarPlacement(-1920, 0, 0, 1080, 1.0,
                                             IdleSpecs());
  EXPECT_LT(p.x, 0);
  EXPECT_LE(p.x + p.width, 0);
  EXPECT_GE(p.x, -1920);
}

TEST(PreRecordingBarPlacementTest, ClampsInsteadOfSpillingOnANarrowWorkArea) {
  // Work area far narrower than the bar's content width.
  const BarPlacement p = ComputeBarPlacement(0, 0, 120, 400, 1.0, IdleSpecs());
  EXPECT_GE(p.x, 0) << "narrow work area pushed the bar off the left edge";
  EXPECT_GE(p.y, 0);
}

TEST(PreRecordingBarPlacementTest, ScalesHeightAndInsetWithDpi) {
  const BarPlacement at100 = PlaceOnPrimary(1.0);
  const BarPlacement at200 = PlaceOnPrimary(2.0);

  EXPECT_EQ(at100.height, kBarBaseHeight);
  EXPECT_EQ(at200.height, kBarBaseHeight * 2);
  EXPECT_GT(at200.width, at100.width);
  // Inset scales too, so the 200% bar sits further off the bottom edge.
  EXPECT_EQ(at200.y + at200.height + kBarBottomInset * 2, kPrimaryB);
}

TEST(PreRecordingBarPlacementTest, AlwaysProducesAPositiveSizedWindow) {
  // Degenerate work area (disconnected display races) must not yield a 0x0
  // window, which would be invisible-but-"visible" just like the original bug.
  const BarPlacement p = ComputeBarPlacement(0, 0, 0, 0, 1.0, IdleSpecs());
  EXPECT_GT(p.width, 0);
  EXPECT_GT(p.height, 0);
}

}  // namespace
}  // namespace clingfy::capture
