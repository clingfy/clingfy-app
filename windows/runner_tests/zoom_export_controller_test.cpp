#include "Capture/Zoom/zoom_export_controller.h"

#include <gtest/gtest.h>

#include <vector>

#include "Capture/Cursor/cursor_sidecar_reader.h"

namespace clingfy::capture {
namespace {

CursorSidecarData MakeData(std::vector<CursorSidecarSample> samples,
                           std::vector<CursorSidecarClick> clicks,
                           std::int32_t w = 1000, std::int32_t h = 1000) {
  CursorSidecarData d;
  d.width = w;
  d.height = h;
  d.target_type = "display";
  d.samples = std::move(samples);
  d.clicks = std::move(clicks);
  return d;
}

// === Focus heuristic =======================================================

TEST(ResolveZoomFocusTest, StaticCursorIsFixedTargetAtClickPoint) {
  // All samples clustered at (300,400) (< 12px spread) → fixedTarget there.
  std::vector<CursorSidecarSample> s = {
      {1000, 300, 400, true}, {1200, 302, 401, true}, {1500, 301, 399, true}};
  const ZoomFocus f = ResolveZoomFocus(s, 1000, 2500, 1000, 1000);
  EXPECT_EQ(f.mode, ZoomFocusMode::kFixedTarget);
  EXPECT_NEAR(f.fixed_x, 0.30, 0.01);
  EXPECT_NEAR(f.fixed_y, 0.40, 0.01);
}

TEST(ResolveZoomFocusTest, MovingCursorIsFollowCursor) {
  std::vector<CursorSidecarSample> s = {
      {1000, 100, 100, true}, {1500, 800, 600, true}};  // big spread
  const ZoomFocus f = ResolveZoomFocus(s, 1000, 2500, 1000, 1000);
  EXPECT_EQ(f.mode, ZoomFocusMode::kFollowCursor);
}

TEST(ResolveZoomFocusTest, NoVisibleSamplesIsFixedCenter) {
  std::vector<CursorSidecarSample> s = {{1000, 300, 400, false}};
  const ZoomFocus f = ResolveZoomFocus(s, 1000, 2500, 1000, 1000);
  EXPECT_EQ(f.mode, ZoomFocusMode::kFixedTarget);
  EXPECT_DOUBLE_EQ(f.fixed_x, 0.5);
  EXPECT_DOUBLE_EQ(f.fixed_y, 0.5);
}

// === Controller construction ===============================================

TEST(ZoomExportControllerTest, NullWhenZoomFactorIsOne) {
  auto data = MakeData({{0, 500, 500, true}, {3000, 500, 500, true}}, {{1000}});
  EXPECT_EQ(ZoomExportController::CreateFromData(data, 3000, 1.0), nullptr);
}

TEST(ZoomExportControllerTest, NullWhenNoClicks) {
  auto data = MakeData({{0, 500, 500, true}, {3000, 500, 500, true}}, {});
  EXPECT_EQ(ZoomExportController::CreateFromData(data, 3000, 2.0), nullptr);
}

TEST(ZoomExportControllerTest, BuildsSegmentsWhenClickedAndZoomed) {
  auto data = MakeData({{0, 500, 500, true}, {3000, 500, 500, true}}, {{1000}});
  auto controller = ZoomExportController::CreateFromData(data, 3000, 2.0);
  ASSERT_NE(controller, nullptr);
  EXPECT_GE(controller->segment_count(), 1u);
}

// === Per-frame convergence (focus stability) ===============================

TEST(ZoomExportControllerTest, ConvergesToZoomAndFixedFocusInsideSegment) {
  // Static cursor at (300,400) with a click at 1000ms → fixedTarget (0.3,0.4).
  std::vector<CursorSidecarSample> s;
  for (std::int64_t t = 0; t <= 3000; t += 100) {
    s.push_back({t, 300, 400, true});
  }
  auto data = MakeData(s, {{1000}});
  auto controller = ZoomExportController::CreateFromData(data, 3000, 2.0);
  ASSERT_NE(controller, nullptr);

  // Advance many frames at a fixed time well inside the segment (~1500ms) so the
  // smoother converges on the target zoom + center (the focus point is stable).
  ZoomExportController::Frame frame;
  for (int i = 0; i < 600; ++i) {
    frame = controller->Advance(1500, 1.0 / 60.0);
  }
  EXPECT_TRUE(frame.active);
  EXPECT_NEAR(frame.zoom, 2.0, 0.02);
  EXPECT_NEAR(frame.center_x, 0.30, 0.01);  // clamped window range [0.25,0.75]
  EXPECT_NEAR(frame.center_y, 0.40, 0.01);
}

TEST(ZoomExportControllerTest, ZoomsBackOutAfterSegment) {
  std::vector<CursorSidecarSample> s;
  for (std::int64_t t = 0; t <= 6000; t += 100) {
    s.push_back({t, 300, 400, true});
  }
  auto data = MakeData(s, {{1000}});
  auto controller = ZoomExportController::CreateFromData(data, 6000, 2.0);
  ASSERT_NE(controller, nullptr);

  // Drive into the segment, then well past it (5500ms — after click+hold ~2500).
  ZoomExportController::Frame frame;
  for (int i = 0; i < 200; ++i) frame = controller->Advance(1500, 1.0 / 60.0);
  ASSERT_GT(frame.zoom, 1.5);
  for (int i = 0; i < 600; ++i) frame = controller->Advance(5500, 1.0 / 60.0);
  EXPECT_FALSE(frame.active);
  EXPECT_NEAR(frame.zoom, 1.0, 0.02);
}

TEST(ZoomExportControllerTest, FollowCursorCenterTracksTheCursor) {
  // Moving cursor (followCursor segment). At a frame where the cursor is at
  // (800,200), the smoothed center should head toward (0.8,0.2) (clamped).
  std::vector<CursorSidecarSample> s = {
      {0, 100, 900, true},    {1000, 100, 900, true}, {1500, 800, 200, true},
      {3000, 800, 200, true}};
  auto data = MakeData(s, {{1000}});
  auto controller = ZoomExportController::CreateFromData(data, 3000, 2.0);
  ASSERT_NE(controller, nullptr);
  ZoomExportController::Frame frame;
  for (int i = 0; i < 600; ++i) frame = controller->Advance(1500, 1.0 / 60.0);
  EXPECT_TRUE(frame.active);
  // (0.8,0.2) clamped to the [0.25,0.75] window range at zoom 2.0.
  EXPECT_NEAR(frame.center_x, 0.75, 0.02);
  EXPECT_NEAR(frame.center_y, 0.25, 0.02);
}

}  // namespace
}  // namespace clingfy::capture
