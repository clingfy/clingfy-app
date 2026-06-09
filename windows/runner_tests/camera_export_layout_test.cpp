#include "Capture/Camera/camera_export_layout.h"

#include <gtest/gtest.h>

#include <vector>

namespace clingfy::capture {
namespace {

// 1920x1080 canvas, 18% size factor → side = min(1920,1080)*0.18 = 194.4px.
constexpr double kW = 1920.0;
constexpr double kH = 1080.0;

TEST(CameraExportLayoutTest, ManualCenterPlacesSquareBubble) {
  const CameraBubbleRect r =
      ComputeCameraBubbleRect(kW, kH, /*has_center=*/true, 0.5, 0.5, "", 0.18);
  EXPECT_DOUBLE_EQ(r.width, r.height);  // always square
  const double side = 1080.0 * 0.18;
  EXPECT_NEAR(r.width, side, 0.001);
  // Centered: x = 0.5*W - side/2.
  EXPECT_NEAR(r.x, kW / 2.0 - side / 2.0, 0.001);
  EXPECT_NEAR(r.y, kH / 2.0 - side / 2.0, 0.001);
}

TEST(CameraExportLayoutTest, SizeFactorClampedToRange) {
  // Use a large canvas so the 0.08 floor stays well above the 96px min-side
  // floor (tested separately) and the factor clamp is what we observe.
  constexpr double big = 4000.0;
  EXPECT_NEAR(ComputeCameraBubbleRect(big, big, true, 0.5, 0.5, "", 0.01).width,
              big * 0.08, 0.001);
  EXPECT_NEAR(ComputeCameraBubbleRect(big, big, true, 0.5, 0.5, "", 0.99).width,
              big * 0.45, 0.001);
}

TEST(CameraExportLayoutTest, MinSideFloorApplies) {
  // Tiny canvas: 200x200 at 0.08 → 16px, floored to the 96px minimum.
  const CameraBubbleRect r =
      ComputeCameraBubbleRect(200.0, 200.0, true, 0.5, 0.5, "", 0.08);
  EXPECT_NEAR(r.width, kCameraBubbleMinSidePx, 0.001);
}

TEST(CameraExportLayoutTest, ClampsFullyOnCanvas) {
  // Center at the far corner would push the bubble off-canvas; it must clamp so
  // the whole square stays inside [0, W]x[0, H].
  const CameraBubbleRect r =
      ComputeCameraBubbleRect(kW, kH, true, 1.0, 1.0, "", 0.45);
  EXPECT_GE(r.x, 0.0);
  EXPECT_GE(r.y, 0.0);
  EXPECT_LE(r.x + r.width, kW + 0.001);
  EXPECT_LE(r.y + r.height, kH + 0.001);
}

TEST(CameraExportLayoutTest, PresetCornersDiffer) {
  const auto br = ComputeCameraBubbleRect(kW, kH, false, 0, 0,
                                          "overlayBottomRight", 0.18);
  const auto tl =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayTopLeft", 0.18);
  const auto tr =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayTopRight", 0.18);
  const auto bl =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayBottomLeft", 0.18);
  // Bottom-right is to the right of + below top-left.
  EXPECT_GT(br.x, tl.x);
  EXPECT_GT(br.y, tl.y);
  // Top-right shares br's x-side but tl's y-side.
  EXPECT_NEAR(tr.x, br.x, 0.001);
  EXPECT_NEAR(tr.y, tl.y, 0.001);
  EXPECT_NEAR(bl.x, tl.x, 0.001);
  EXPECT_NEAR(bl.y, br.y, 0.001);
}

TEST(CameraExportLayoutTest, UnknownPresetFallsBackToBottomRight) {
  const auto unknown =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "sideBySideLeft", 0.18);
  const auto br = ComputeCameraBubbleRect(kW, kH, false, 0, 0,
                                          "overlayBottomRight", 0.18);
  EXPECT_NEAR(unknown.x, br.x, 0.001);
  EXPECT_NEAR(unknown.y, br.y, 0.001);
}

TEST(CameraExportLayoutTest, DegenerateCanvasIsEmpty) {
  const auto r = ComputeCameraBubbleRect(0.0, 0.0, true, 0.5, 0.5, "", 0.18);
  EXPECT_DOUBLE_EQ(r.width, 0.0);
  EXPECT_DOUBLE_EQ(r.height, 0.0);
}

// --- time alignment ---------------------------------------------------------

TEST(CameraExportSyncTest, CameraTimeSubtractsStartOffset) {
  EXPECT_EQ(CameraTimeMsForFrame(1000, 150), 850);
  EXPECT_EQ(CameraTimeMsForFrame(150, 150), 0);
  EXPECT_EQ(CameraTimeMsForFrame(100, 150), -50);  // before camera start
}

TEST(CameraExportSyncTest, HeldFrameSelection) {
  const std::vector<std::int64_t> frames = {0, 33, 66, 100, 133};
  EXPECT_EQ(SelectHeldCameraFrameIndex(-1, frames), -1);   // negative time
  EXPECT_EQ(SelectHeldCameraFrameIndex(0, frames), 0);     // exactly first
  EXPECT_EQ(SelectHeldCameraFrameIndex(50, frames), 1);    // hold 33
  EXPECT_EQ(SelectHeldCameraFrameIndex(66, frames), 2);    // exactly third
  EXPECT_EQ(SelectHeldCameraFrameIndex(9999, frames), 4);  // hold last
}

TEST(CameraExportSyncTest, BeforeFirstFrameHoldsNothing) {
  const std::vector<std::int64_t> frames = {200, 233, 266};
  // camera_ms past start (>=0) but before the first recorded frame → nothing.
  EXPECT_EQ(SelectHeldCameraFrameIndex(100, frames), -1);
}

TEST(CameraExportSyncTest, AlignmentAcrossPauseGapHolds) {
  // Pause-aware timestamps: a gap in recorded camera frames (paused region).
  // After resume the alignment still picks the latest frame <= camera time.
  const std::vector<std::int64_t> frames = {0, 33, 66, /*resume*/ 500, 533};
  EXPECT_EQ(SelectHeldCameraFrameIndex(100, frames), 2);   // held through pause
  EXPECT_EQ(SelectHeldCameraFrameIndex(499, frames), 2);   // still held at gap
  EXPECT_EQ(SelectHeldCameraFrameIndex(500, frames), 3);   // resume frame
}

// --- shadow style (Phase 9.5) -----------------------------------------------

TEST(CameraShadowStyleTest, PresetZeroAndUnknownDisabled) {
  EXPECT_FALSE(ResolveCameraShadowStyle(0).enabled);
  EXPECT_FALSE(ResolveCameraShadowStyle(-1).enabled);
  EXPECT_FALSE(ResolveCameraShadowStyle(99).enabled);
}

TEST(CameraShadowStyleTest, PresetsMatchMacOsParityWithFlippedY) {
  // macOS uses a y-UP space (offset.height -2/-4/-6); D2D is y-DOWN so the
  // shadow drops with a POSITIVE y. Opacity/radius mirror macOS shadowStyle.
  const auto s1 = ResolveCameraShadowStyle(1);
  EXPECT_TRUE(s1.enabled);
  EXPECT_DOUBLE_EQ(s1.opacity, 0.18);
  EXPECT_DOUBLE_EQ(s1.blur_radius, 10.0);
  EXPECT_DOUBLE_EQ(s1.offset_x, 0.0);
  EXPECT_DOUBLE_EQ(s1.offset_y, 2.0);

  const auto s2 = ResolveCameraShadowStyle(2);
  EXPECT_DOUBLE_EQ(s2.opacity, 0.24);
  EXPECT_DOUBLE_EQ(s2.blur_radius, 16.0);
  EXPECT_DOUBLE_EQ(s2.offset_y, 4.0);

  const auto s3 = ResolveCameraShadowStyle(3);
  EXPECT_DOUBLE_EQ(s3.opacity, 0.32);
  EXPECT_DOUBLE_EQ(s3.blur_radius, 22.0);
  EXPECT_DOUBLE_EQ(s3.offset_y, 6.0);
}

TEST(CameraShadowStyleTest, StrongerPresetMeansMoreOpacityAndBlur) {
  const auto s1 = ResolveCameraShadowStyle(1);
  const auto s2 = ResolveCameraShadowStyle(2);
  const auto s3 = ResolveCameraShadowStyle(3);
  EXPECT_LT(s1.opacity, s2.opacity);
  EXPECT_LT(s2.opacity, s3.opacity);
  EXPECT_LT(s1.blur_radius, s2.blur_radius);
  EXPECT_LT(s2.blur_radius, s3.blur_radius);
}

}  // namespace
}  // namespace clingfy::capture
