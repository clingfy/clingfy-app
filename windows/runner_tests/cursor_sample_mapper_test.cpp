#include "Capture/Cursor/cursor_sample_mapper.h"

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

// === Coordinate mapping ====================================================
//
// The per-target origin (display monitor origin / area monitor+crop / window
// DWM content origin) is resolved by the sampler via Win32; this pure helper
// just subtracts the origin and bounds-checks. The tests feed origins that
// represent each mode so the mapping is verified without a real
// monitor/window/GPU.

TEST(CursorSampleMapperTest, DisplayModeSubtractsMonitorOrigin) {
  // Primary monitor at virtual-desktop origin (0,0), 1920x1080.
  const auto p = MapScreenToCaptureLocal(/*sx=*/100, /*sy=*/50,
                                         /*origin_x=*/0, /*origin_y=*/0,
                                         /*w=*/1920, /*h=*/1080);
  EXPECT_EQ(p.x, 100);
  EXPECT_EQ(p.y, 50);
  EXPECT_TRUE(p.visible);
}

TEST(CursorSampleMapperTest, DisplayModeSecondaryMonitorOrigin) {
  // A second monitor positioned to the right of primary: origin (1920,0).
  const auto p = MapScreenToCaptureLocal(2020, 50, 1920, 0, 1920, 1080);
  EXPECT_EQ(p.x, 100);
  EXPECT_EQ(p.y, 50);
  EXPECT_TRUE(p.visible);
}

TEST(CursorSampleMapperTest, DisplayModeNegativeOriginMonitor) {
  // A monitor left of / above primary has a negative virtual-desktop origin.
  const auto p = MapScreenToCaptureLocal(-1820, -1030, -1920, -1080, 1920, 1080);
  EXPECT_EQ(p.x, 100);
  EXPECT_EQ(p.y, 50);
  EXPECT_TRUE(p.visible);
}

TEST(CursorSampleMapperTest, AreaModeSubtractsMonitorPlusCropOrigin) {
  // Area capture on the primary monitor: crop at (200,150), 800x600 → the
  // capture-region origin is monitor(0,0)+crop(200,150).
  const auto p = MapScreenToCaptureLocal(/*sx=*/250, /*sy=*/200,
                                         /*origin_x=*/200, /*origin_y=*/150,
                                         /*w=*/800, /*h=*/600);
  EXPECT_EQ(p.x, 50);
  EXPECT_EQ(p.y, 50);
  EXPECT_TRUE(p.visible);
}

TEST(CursorSampleMapperTest, AreaModeOnSecondaryMonitorWithCrop) {
  // Secondary monitor origin (1920,0), crop (100,100) → origin (2020,100).
  const auto p = MapScreenToCaptureLocal(2040, 130, 2020, 100, 640, 480);
  EXPECT_EQ(p.x, 20);
  EXPECT_EQ(p.y, 30);
  EXPECT_TRUE(p.visible);
}

TEST(CursorSampleMapperTest, WindowModeUsesContentOriginNotWindowRect) {
  // A window's WGC frame (0,0) is the CONTENT top-left (DWM extended frame
  // bounds), which sits INSIDE GetWindowRect by the invisible drop-shadow
  // border. Say the window rect is at (300,300) but the content origin is
  // (308,300) (8px shadow on the left). A cursor at the content top-left maps
  // to (0,0), proving we must use the content origin, not the window rect.
  const std::int32_t content_origin_x = 308;
  const std::int32_t content_origin_y = 300;
  const auto top_left = MapScreenToCaptureLocal(
      content_origin_x, content_origin_y, content_origin_x, content_origin_y,
      1280, 720);
  EXPECT_EQ(top_left.x, 0);
  EXPECT_EQ(top_left.y, 0);
  EXPECT_TRUE(top_left.visible);

  // A point at the window-rect origin (8px left of the content) maps to a
  // NEGATIVE x → outside the captured content (not visible).
  const auto in_shadow = MapScreenToCaptureLocal(300, 300, content_origin_x,
                                                 content_origin_y, 1280, 720);
  EXPECT_EQ(in_shadow.x, -8);
  EXPECT_FALSE(in_shadow.visible);
}

TEST(CursorSampleMapperTest, OutsideBoundsIsNotVisible) {
  // Past the right/bottom edge.
  EXPECT_FALSE(MapScreenToCaptureLocal(1920, 0, 0, 0, 1920, 1080).visible);
  EXPECT_FALSE(MapScreenToCaptureLocal(0, 1080, 0, 0, 1920, 1080).visible);
  // Before the origin.
  EXPECT_FALSE(MapScreenToCaptureLocal(-1, 10, 0, 0, 1920, 1080).visible);
  // Exact bottom-right inside corner is visible; one past is not.
  EXPECT_TRUE(MapScreenToCaptureLocal(1919, 1079, 0, 0, 1920, 1080).visible);
}

TEST(CursorSampleMapperTest, ZeroSizeRegionIsNeverVisible) {
  EXPECT_FALSE(MapScreenToCaptureLocal(0, 0, 0, 0, 0, 0).visible);
}

// === Dedup decision ========================================================

TEST(ShouldEmitCursorSampleTest, AlwaysEmitsFirstSample) {
  EXPECT_TRUE(ShouldEmitCursorSample(/*have_prev=*/false, 0, 0, false, 10, 10,
                                     true, /*ms_since=*/0, /*heartbeat=*/1000));
}

TEST(ShouldEmitCursorSampleTest, EmitsOnPositionChangeWhileVisible) {
  EXPECT_TRUE(ShouldEmitCursorSample(true, 10, 10, true, 11, 10, true, 5, 1000));
}

TEST(ShouldEmitCursorSampleTest, EmitsOnVisibilityChange) {
  EXPECT_TRUE(ShouldEmitCursorSample(true, 10, 10, true, 10, 10, false, 5,
                                     1000));
}

TEST(ShouldEmitCursorSampleTest, SkipsUnchangedWithinHeartbeat) {
  EXPECT_FALSE(ShouldEmitCursorSample(true, 10, 10, true, 10, 10, true,
                                      /*ms_since=*/500, /*heartbeat=*/1000));
}

TEST(ShouldEmitCursorSampleTest, EmitsHeartbeatWhenStaticTooLong) {
  EXPECT_TRUE(ShouldEmitCursorSample(true, 10, 10, true, 10, 10, true,
                                     /*ms_since=*/1000, /*heartbeat=*/1000));
}

TEST(ShouldEmitCursorSampleTest, IgnoresPositionChangeWhileNotVisible) {
  // Two off-surface positions are indistinguishable downstream → no emit
  // (until the heartbeat).
  EXPECT_FALSE(ShouldEmitCursorSample(true, -5, -5, false, -9, -9, false,
                                      /*ms_since=*/10, /*heartbeat=*/1000));
}

}  // namespace
}  // namespace clingfy::capture
