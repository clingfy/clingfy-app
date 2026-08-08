// The inline preview's cursor/zoom input, tested against the bytes the REAL
// recorder writes.
//
// Why this file exists: the preview used to carry its own JSONL loader from
// the frame-server POC, which hard-required a `ts_us` field. `CursorSidecarWriter`
// has never emitted that field — it writes `tMs`. So on every real project the
// preview parsed ZERO cursor events, which silently disabled the preview's
// zoom, its cursor halo, and (because the camera is handed a constant
// screen_zoom of 1.0) the camera's scale-with-zoom as well. It also made
// `CURSOR_FILE_MISSING` fire on every open, which Dart answers by
// force-disabling the user's cursor toggle.
//
// Nothing caught it because nothing tested the preview's loader with real
// input. The preview now shares `capture::ParseCursorSidecar` with the export,
// so a second parser cannot drift again — and these tests pin the seam that
// remains: the MS/US unit boundary between the sidecar and the preview clock.

#include "preview/preview_compositor.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "Capture/Cursor/cursor_sidecar_reader.h"
#include "Capture/Cursor/cursor_sidecar_writer.h"
#include "Capture/Zoom/zoom_timeline_builder.h"

namespace clingfy::preview {
namespace {

// Exactly the shape CursorSidecarWriter emits (see cursor_sidecar_writer.cpp).
// Written literally rather than by calling the writer so a change to EITHER
// side has to be looked at rather than silently agreed with itself.
std::string RealRecorderJsonl() {
  return
      R"({"type":"header","schemaVersion":1,"sampleRateHz":60,"targetType":"display","width":1920,"height":1080,"originX":0,"originY":0})"
      "\n"
      R"({"type":"sample","tMs":0,"screenX":100,"screenY":100,"x":100,"y":100,"visible":true})"
      "\n"
      R"({"type":"sample","tMs":1000,"screenX":400,"screenY":300,"x":400,"y":300,"visible":true})"
      "\n"
      R"({"type":"click","tMs":1000,"screenX":400,"screenY":300,"button":"left","action":"down"})"
      "\n"
      R"({"type":"sample","tMs":2000,"screenX":800,"screenY":600,"x":800,"y":600,"visible":true})"
      "\n";
}

TEST(PreviewCursorSidecarTest, RealRecorderBytesProduceSamplesAndClicks) {
  // The regression itself: the preview's input must be non-empty for a real
  // recording. Zero samples here means no zoom, no halo, no scale-with-zoom.
  const auto parsed = capture::ParseCursorSidecar(RealRecorderJsonl());
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(parsed->samples.size(), 3u);
  ASSERT_EQ(parsed->clicks.size(), 1u);
  EXPECT_EQ(parsed->clicks[0].t_ms, 1000);
}

TEST(PreviewCursorSidecarTest, PreviewAndExportResolveTheSameSegments) {
  // THE parity property. The preview used to decide "is a zoom wanted" with a
  // symmetric +/-500 ms window around the nearest click; the export builds
  // segments with hysteresis, a 120 ms gap-merge, a minimum length and a
  // visibility gate, and BACKDATES each segment's start to the click. Those two
  // rules disagree by up to half a second at every onset.
  //
  // Both legs now call ZoomSegmentStateAt on segments from the same builder, so
  // the assertion is that one function is the only source of truth.
  const auto parsed = capture::ParseCursorSidecar(RealRecorderJsonl());
  ASSERT_TRUE(parsed.has_value());
  const auto segments = capture::BuildZoomSegments(
      parsed->samples, parsed->clicks, /*duration_ms=*/0);
  ASSERT_FALSE(segments.empty()) << "a click must produce a zoom segment";

  // Before the click there is no segment — the old preview would already have
  // been zooming here, 500 ms early.
  EXPECT_FALSE(capture::ZoomSegmentStateAt(segments, 400).in_segment);

  // Inside, local time is measured from the segment START, not from a click
  // lookup and not from playback position.
  const auto at_start =
      capture::ZoomSegmentStateAt(segments, segments[0].start_ms);
  EXPECT_TRUE(at_start.in_segment);
  EXPECT_EQ(at_start.local_ms, 0);

  const auto mid =
      capture::ZoomSegmentStateAt(segments, segments[0].start_ms + 250);
  EXPECT_TRUE(mid.in_segment);
  EXPECT_EQ(mid.local_ms, 250);
}

TEST(PreviewCursorSidecarTest, SegmentMembershipIsHalfOpenAtTheEnd) {
  // end_ms is NOT in the segment. That boundary is where a zoom-local clock
  // must stop: the smoothed zoom keeps easing out afterwards, but the segment
  // is over. Anything keyed off "zoom > 1" instead keeps running through the
  // tail and then stops at an arbitrary phase.
  const std::vector<capture::ZoomSegment> segments = {{1000, 2500}};
  EXPECT_FALSE(capture::ZoomSegmentStateAt(segments, 999).in_segment);
  EXPECT_TRUE(capture::ZoomSegmentStateAt(segments, 1000).in_segment);
  EXPECT_TRUE(capture::ZoomSegmentStateAt(segments, 2499).in_segment);
  EXPECT_FALSE(capture::ZoomSegmentStateAt(segments, 2500).in_segment)
      << "end_ms must be outside the segment";
  EXPECT_FALSE(capture::ZoomSegmentStateAt(segments, 3000).in_segment);
}

TEST(PreviewCursorSidecarTest, MergedClicksShareOnePhaseOrigin) {
  // Two clicks close together merge into ONE segment, so local time keeps
  // running from the FIRST click. A per-click clock would restart here, which
  // is the concrete failure the old last_click_ts_us approach would have had.
  capture::CursorSidecarData data;
  data.samples.push_back({0, 100, 100, true});
  data.samples.push_back({3000, 400, 400, true});
  data.clicks.push_back({500});
  data.clicks.push_back({900});
  const auto segments =
      capture::BuildZoomSegments(data.samples, data.clicks, /*duration_ms=*/0);
  ASSERT_EQ(segments.size(), 1u) << "adjacent clicks must gap-merge";
  const auto later = capture::ZoomSegmentStateAt(segments, 1500);
  EXPECT_TRUE(later.in_segment);
  EXPECT_EQ(later.local_ms, 1500 - segments[0].start_ms)
      << "the second click must not restart the phase origin";
}

TEST(PreviewCursorSidecarTest, NoSegmentsMeansNeverActive) {
  const std::vector<capture::ZoomSegment> none;
  EXPECT_FALSE(capture::ZoomSegmentStateAt(none, 0).in_segment);
  EXPECT_FALSE(capture::ZoomSegmentStateAt(none, 5000).in_segment);
}

TEST(PreviewCursorSidecarTest, PocTsUsFormatIsNoLongerAccepted) {
  // The POC format now lives only in mediaplayer_frame_server_demo.cpp. If it
  // ever comes back into the shared path, this passes again and the preview
  // silently starts accepting a format the recorder does not write.
  const std::string poc =
      R"({"ts_us":0,"x":10,"y":20,"button_state":0,"monitor_id":0})"
      "\n"
      R"({"ts_us":500000,"x":30,"y":40,"button_state":1,"monitor_id":0})"
      "\n";
  const auto parsed = capture::ParseCursorSidecar(poc);
  EXPECT_FALSE(parsed.has_value())
      << "the shared reader accepted the POC ts_us format; the preview must "
         "read only what the recorder writes";
}

}  // namespace
}  // namespace clingfy::preview
