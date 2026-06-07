#include "Capture/Zoom/zoom_timeline_builder.h"

#include <gtest/gtest.h>

#include <vector>

#include "Capture/Cursor/cursor_sidecar_reader.h"

namespace clingfy::capture {
namespace {

// A visible cursor sample every 100ms across [0, duration].
std::vector<CursorSidecarSample> VisibleSamples(std::int64_t duration_ms,
                                                bool visible = true) {
  std::vector<CursorSidecarSample> out;
  for (std::int64_t t = 0; t <= duration_ms; t += 100) {
    out.push_back({t, 500, 500, visible});
  }
  return out;
}

TEST(ZoomTimelineBuilderTest, SingleClickProducesOneSegmentSpanningHold) {
  const auto samples = VisibleSamples(4000);
  std::vector<CursorSidecarClick> clicks = {{1000}};
  const auto segs = BuildZoomSegments(samples, clicks, 4000);
  ASSERT_EQ(segs.size(), 1u);
  // Segment boundaries follow the raw click-hold window [click, click+hold],
  // not the hysteresis-delayed edges. hold = 1.5s → ~[1000, 2500] (+/- one
  // sim frame at 60fps).
  EXPECT_GE(segs[0].start_ms, 980);
  EXPECT_LE(segs[0].start_ms, 1020);
  EXPECT_GE(segs[0].end_ms, 2480);
  EXPECT_LE(segs[0].end_ms, 2560);
}

TEST(ZoomTimelineBuilderTest, NoClicksProducesNoSegments) {
  const auto samples = VisibleSamples(3000);
  EXPECT_TRUE(BuildZoomSegments(samples, {}, 3000).empty());
}

TEST(ZoomTimelineBuilderTest, NoSamplesProducesNoSegments) {
  std::vector<CursorSidecarClick> clicks = {{1000}};
  EXPECT_TRUE(BuildZoomSegments({}, clicks, 3000).empty());
}

TEST(ZoomTimelineBuilderTest, CursorOffScreenSuppressesZoom) {
  // The cursor is never visible → the in-bounds gate never opens → no segment
  // even though a click occurred.
  const auto samples = VisibleSamples(3000, /*visible=*/false);
  std::vector<CursorSidecarClick> clicks = {{1000}};
  EXPECT_TRUE(BuildZoomSegments(samples, clicks, 3000).empty());
}

TEST(ZoomTimelineBuilderTest, NearbyClicksMergeIntoOneSegment) {
  // Two clicks within the hold window keep zoom continuously wanted → one
  // segment spanning from the first click to the second click + hold.
  const auto samples = VisibleSamples(6000);
  std::vector<CursorSidecarClick> clicks = {{1000}, {1800}};
  const auto segs = BuildZoomSegments(samples, clicks, 6000);
  ASSERT_EQ(segs.size(), 1u);
  EXPECT_GE(segs[0].start_ms, 980);
  EXPECT_LE(segs[0].start_ms, 1020);
  // Last click 1800 + hold 1500 = ~3300.
  EXPECT_GE(segs[0].end_ms, 3280);
  EXPECT_LE(segs[0].end_ms, 3360);
}

TEST(ZoomTimelineBuilderTest, FarApartClicksProduceTwoSegments) {
  const auto samples = VisibleSamples(8000);
  std::vector<CursorSidecarClick> clicks = {{1000}, {5000}};
  const auto segs = BuildZoomSegments(samples, clicks, 8000);
  EXPECT_EQ(segs.size(), 2u);
}

}  // namespace
}  // namespace clingfy::capture
