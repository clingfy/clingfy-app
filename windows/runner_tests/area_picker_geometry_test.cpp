#include "Overlay/area_picker_geometry.h"

#include <gtest/gtest.h>

namespace clingfy::overlay {
namespace {

// ---- ScreenToMonitorLocal ---------------------------------------------------

TEST(ScreenToMonitorLocalTest, PrimaryOriginIsIdentity) {
  const auto p = ScreenToMonitorLocal(100, 50, 0, 0);
  EXPECT_EQ(p.x, 100);
  EXPECT_EQ(p.y, 50);
}

TEST(ScreenToMonitorLocalTest, SecondaryToTheRightSubtractsOrigin) {
  const auto p = ScreenToMonitorLocal(2020, 50, 1920, 0);
  EXPECT_EQ(p.x, 100);
  EXPECT_EQ(p.y, 50);
}

TEST(ScreenToMonitorLocalTest, NegativeOriginMonitorConvertsCorrectly) {
  // A display positioned left of / above the primary has a negative origin.
  EXPECT_EQ(ScreenToMonitorLocal(-1820, 50, -1920, 0).x, 100);
  EXPECT_EQ(ScreenToMonitorLocal(-1820, 50, -1920, 0).y, 50);
  EXPECT_EQ(ScreenToMonitorLocal(100, -1030, 0, -1080).y, 50);
}

// ---- ResolvePickedRect ------------------------------------------------------

TEST(ResolvePickedRectTest, NormalDragNormalizes) {
  const auto r = ResolvePickedRect(100, 50, 500, 400, 1920, 1080, kMinAreaSize);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->x, 100u);
  EXPECT_EQ(r->y, 50u);
  EXPECT_EQ(r->width, 400u);
  EXPECT_EQ(r->height, 350u);
}

TEST(ResolvePickedRectTest, ReversedDragInBothAxesNormalizesToSameRect) {
  const auto down_right =
      ResolvePickedRect(100, 50, 500, 400, 1920, 1080, kMinAreaSize);
  const auto up_left =
      ResolvePickedRect(500, 400, 100, 50, 1920, 1080, kMinAreaSize);
  ASSERT_TRUE(down_right.has_value());
  ASSERT_TRUE(up_left.has_value());
  EXPECT_EQ(up_left->x, down_right->x);
  EXPECT_EQ(up_left->y, down_right->y);
  EXPECT_EQ(up_left->width, down_right->width);
  EXPECT_EQ(up_left->height, down_right->height);
}

TEST(ResolvePickedRectTest, ClampsToMonitorBounds) {
  // Drag runs off the right/bottom edge -> clamped to what fits.
  const auto r =
      ResolvePickedRect(1800, 1000, 2200, 1300, 1920, 1080, kMinAreaSize);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->x, 1800u);
  EXPECT_EQ(r->y, 1000u);
  EXPECT_EQ(r->width, 120u);   // 1920 - 1800
  EXPECT_EQ(r->height, 80u);   // 1080 - 1000
}

TEST(ResolvePickedRectTest, NegativeStartClampsToZero) {
  const auto r =
      ResolvePickedRect(-50, -30, 200, 150, 1920, 1080, kMinAreaSize);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->x, 0u);
  EXPECT_EQ(r->y, 0u);
  EXPECT_EQ(r->width, 200u);
  EXPECT_EQ(r->height, 150u);
}

TEST(ResolvePickedRectTest, OddDimensionsClampDownToEven) {
  const auto r = ResolvePickedRect(0, 0, 401, 301, 1920, 1080, kMinAreaSize);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->width, 400u);
  EXPECT_EQ(r->height, 300u);
}

TEST(ResolvePickedRectTest, TinySelectionIsRejected) {
  // 10x8 -> below the 16px minimum -> no selection.
  EXPECT_FALSE(
      ResolvePickedRect(100, 100, 110, 108, 1920, 1080, kMinAreaSize)
          .has_value());
  // 15px even-aligns to 14, still below 16 -> rejected.
  EXPECT_FALSE(
      ResolvePickedRect(0, 0, 15, 15, 1920, 1080, kMinAreaSize).has_value());
}

TEST(ResolvePickedRectTest, ExactlyMinSizeIsAccepted) {
  const auto r = ResolvePickedRect(0, 0, 16, 16, 1920, 1080, kMinAreaSize);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->width, 16u);
  EXPECT_EQ(r->height, 16u);
}

TEST(ResolvePickedRectTest, EmptyMonitorYieldsNullopt) {
  EXPECT_FALSE(
      ResolvePickedRect(0, 0, 100, 100, 0, 0, kMinAreaSize).has_value());
}

}  // namespace
}  // namespace clingfy::overlay
