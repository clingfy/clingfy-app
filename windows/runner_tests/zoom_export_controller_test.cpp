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

// === Fixed-target zoom: the user's pinned point ==========================

TEST(ZoomExportControllerTest, APinnedSegmentZoomsOnItsPointNotTheCursor) {
  // The cursor moves the whole time, so the heuristic alone would follow it.
  // The user pinned the segment at (0.6, 0.35): the export must sit there.
  std::vector<CursorSidecarSample> s;
  for (std::int64_t t = 0; t <= 3000; t += 100) {
    s.push_back({t, static_cast<std::int32_t>(100 + t / 4), 900, true});
  }
  ZoomSegment pinned{1000, 2500};
  pinned.fixed_target = true;
  pinned.target_x = 0.6;
  pinned.target_y = 0.35;
  auto controller =
      ZoomExportController::CreateFromSegments(MakeData(s, {}), {pinned}, 2.0);
  ASSERT_NE(controller, nullptr);
  ZoomExportController::Frame frame;
  for (int i = 0; i < 600; ++i) frame = controller->Advance(1800, 1.0 / 60.0);
  EXPECT_TRUE(frame.active);
  EXPECT_NEAR(frame.center_x, 0.60, 0.01);
  EXPECT_NEAR(frame.center_y, 0.35, 0.01);
}

TEST(ZoomExportControllerTest, APinnedPointNearTheEdgeIsClampedLikeAnyFocus) {
  // At 2x the window is half the frame, so its centre cannot pass 0.25 /
  // 0.75 without revealing background. A corner pin is held at the limit.
  ZoomSegment pinned{0, 2000};
  pinned.fixed_target = true;
  pinned.target_x = 1.0;
  pinned.target_y = 0.0;
  auto controller = ZoomExportController::CreateFromSegments(
      MakeData({{0, 500, 500, true}}, {}), {pinned}, 2.0);
  ASSERT_NE(controller, nullptr);
  ZoomExportController::Frame frame;
  for (int i = 0; i < 600; ++i) frame = controller->Advance(1000, 1.0 / 60.0);
  EXPECT_NEAR(frame.center_x, 0.75, 0.01);
  EXPECT_NEAR(frame.center_y, 0.25, 0.01);
}

TEST(ZoomSegmentStateAtTest, ReportsTheActiveSegmentsPinnedPoint) {
  ZoomSegment follow{0, 1000};
  ZoomSegment pinned{1000, 2000};
  pinned.fixed_target = true;
  pinned.target_x = 0.2;
  pinned.target_y = 0.7;
  const std::vector<ZoomSegment> segments{follow, pinned};

  const ZoomSegmentState a = ZoomSegmentStateAt(segments, 500);
  EXPECT_TRUE(a.in_segment);
  EXPECT_FALSE(a.fixed_target);

  const ZoomSegmentState b = ZoomSegmentStateAt(segments, 1500);
  EXPECT_TRUE(b.in_segment);
  EXPECT_EQ(b.local_ms, 500);
  EXPECT_TRUE(b.fixed_target);
  EXPECT_DOUBLE_EQ(b.target_x, 0.2);
  EXPECT_DOUBLE_EQ(b.target_y, 0.7);

  EXPECT_FALSE(ZoomSegmentStateAt(segments, 2000).fixed_target);
}

// === Cursor samples for the editor's focus heuristic ======================

TEST(SelectCursorSamplesTest, InclusiveRangeAndNearestToThePlayhead) {
  const std::vector<CursorSidecarSample> s = {
      {0, 1, 1, true}, {100, 2, 2, true}, {200, 3, 3, false},
      {300, 4, 4, true}, {400, 5, 5, true}};
  const CursorSampleWindow w = SelectCursorSamples(s, 100, 300, 250);
  ASSERT_EQ(w.in_range.size(), 3u);  // 100, 200 and 300: both ends included
  EXPECT_EQ(w.in_range.front().t_ms, 100);
  EXPECT_EQ(w.in_range.back().t_ms, 300);
  EXPECT_FALSE(w.in_range[1].visible);  // visibility is passed through
  ASSERT_TRUE(w.has_nearest);
  EXPECT_EQ(w.nearest.t_ms, 200);  // a 50 ms tie with 300: the earlier wins
}

TEST(SelectCursorSamplesTest, NoSamplesMeansNoNearest) {
  const CursorSampleWindow w = SelectCursorSamples({}, 0, 1000, 500);
  EXPECT_TRUE(w.in_range.empty());
  EXPECT_FALSE(w.has_nearest);
}

TEST(SelectCursorSamplesTest, ThePlayheadNeedNotBeInsideTheRange) {
  const std::vector<CursorSidecarSample> s = {{0, 1, 1, true},
                                              {900, 2, 2, true}};
  const CursorSampleWindow w = SelectCursorSamples(s, 400, 500, 1000);
  EXPECT_TRUE(w.in_range.empty());
  ASSERT_TRUE(w.has_nearest);
  EXPECT_EQ(w.nearest.t_ms, 900);
}

}  // namespace
}  // namespace clingfy::capture
