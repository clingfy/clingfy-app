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

#include "Capture/Cursor/cursor_sidecar_reader.h"
#include "Capture/Cursor/cursor_sidecar_writer.h"

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

TEST(PreviewCursorSidecarTest, ClickLookupWindowIsInterpretedInMilliseconds) {
  // The one unit boundary the preview still owns: the sidecar is keyed in MS,
  // the preview's playback clock is US, and the ±500 ms lookup constant is
  // declared in US. A slip either way is silent — divide-by-1000 missing makes
  // the window 500 SECONDS wide (every click always matches), and an extra
  // divide makes it 0.5 ms (no click ever matches). Both look like "zoom is
  // broken" on device and neither shows up in a formula test.
  const auto parsed = capture::ParseCursorSidecar(RealRecorderJsonl());
  ASSERT_TRUE(parsed.has_value());
  constexpr std::int64_t kWindowMs = kClickLookupWindowUs / 1000;
  EXPECT_EQ(kWindowMs, 500);

  // At the click.
  EXPECT_NE(FindCursorClickWithin(parsed->clicks, 1000, kWindowMs), nullptr);
  // Inside the window on both sides (it is symmetric today — the export's
  // segments are not, which is what slice 1 reconciles).
  EXPECT_NE(FindCursorClickWithin(parsed->clicks, 1499, kWindowMs), nullptr);
  EXPECT_NE(FindCursorClickWithin(parsed->clicks, 501, kWindowMs), nullptr);
  // Outside it.
  EXPECT_EQ(FindCursorClickWithin(parsed->clicks, 1600, kWindowMs), nullptr);
  EXPECT_EQ(FindCursorClickWithin(parsed->clicks, 0, kWindowMs), nullptr);
  // A 500-second window would swallow this; a 0.5 ms one would fail the first
  // assertion above.
  EXPECT_EQ(FindCursorClickWithin(parsed->clicks, 400'000, kWindowMs), nullptr);
}

TEST(PreviewCursorSidecarTest, PicksTheNearestClickNotTheFirst) {
  capture::CursorSidecarData data;
  data.clicks.push_back({600});
  data.clicks.push_back({1400});
  const auto* near_first = FindCursorClickWithin(data.clicks, 700, 500);
  ASSERT_NE(near_first, nullptr);
  EXPECT_EQ(near_first->t_ms, 600);
  const auto* near_second = FindCursorClickWithin(data.clicks, 1300, 500);
  ASSERT_NE(near_second, nullptr);
  EXPECT_EQ(near_second->t_ms, 1400);
}

TEST(PreviewCursorSidecarTest, NoClicksIsNotAMatch) {
  capture::CursorSidecarData empty;
  EXPECT_EQ(FindCursorClickWithin(empty.clicks, 0, 500), nullptr);
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
