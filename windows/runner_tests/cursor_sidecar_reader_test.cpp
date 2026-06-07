#include "Capture/Cursor/cursor_sidecar_reader.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace clingfy::capture {
namespace {

std::string Header(const char* target = "display", int w = 1920,
                   int h = 1080) {
  return std::string("{\"type\":\"header\",\"schemaVersion\":1,"
                     "\"sampleRateHz\":60,\"targetType\":\"") +
         target + "\",\"width\":" + std::to_string(w) +
         ",\"height\":" + std::to_string(h) + ",\"originX\":0,\"originY\":0}\n";
}

// === Parser ================================================================

TEST(CursorSidecarReaderTest, ParsesHeaderAndSamples) {
  const std::string jsonl =
      Header() +
      "{\"type\":\"sample\",\"tMs\":0,\"screenX\":10,\"screenY\":20,\"x\":10,"
      "\"y\":20,\"visible\":true}\n"
      "{\"type\":\"sample\",\"tMs\":16,\"screenX\":30,\"screenY\":40,\"x\":30,"
      "\"y\":40,\"visible\":true}\n";
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  EXPECT_EQ(data->width, 1920);
  EXPECT_EQ(data->height, 1080);
  EXPECT_EQ(data->target_type, "display");
  ASSERT_EQ(data->samples.size(), 2u);
  EXPECT_EQ(data->samples[0].t_ms, 0);
  EXPECT_EQ(data->samples[0].x, 10);
  EXPECT_TRUE(data->samples[0].visible);
  EXPECT_EQ(data->samples[1].x, 30);
}

TEST(CursorSidecarReaderTest, MissingHeaderReturnsNullopt) {
  const std::string jsonl =
      "{\"type\":\"sample\",\"tMs\":0,\"x\":1,\"y\":2,\"visible\":true}\n";
  EXPECT_FALSE(ParseCursorSidecar(jsonl).has_value());
  EXPECT_FALSE(ParseCursorSidecar("").has_value());
  EXPECT_FALSE(ParseCursorSidecar("garbage not json\n").has_value());
}

TEST(CursorSidecarReaderTest, SkipsMalformedAndIgnoresClicksAndTruncatedTail) {
  const std::string jsonl =
      Header() +
      "{\"type\":\"sample\",\"tMs\":0,\"x\":1,\"y\":2,\"visible\":true}\n"
      "{\"type\":\"click\",\"tMs\":5,\"button\":\"left\",\"action\":\"down\"}\n"
      "{\"type\":\"sample\",\"tMs\":\"oops\"}\n"        // malformed → skipped
      "{\"type\":\"sample\",\"tMs\":16,\"x\":3,\"y\":4,\"visible\":false}\n"
      "{\"type\":\"sample\",\"tMs\":33,\"x\":5,\"y";    // truncated tail
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  // Only the two well-formed sample lines survive; click + malformed + truncated
  // are dropped without failing the parse.
  ASSERT_EQ(data->samples.size(), 2u);
  EXPECT_EQ(data->samples[0].t_ms, 0);
  EXPECT_EQ(data->samples[1].t_ms, 16);
  EXPECT_FALSE(data->samples[1].visible);
}

TEST(CursorSidecarReaderTest, ToleratesCrlfLineEndings) {
  // A file that round-tripped through git autocrlf / a text-mode copy has \r\n.
  std::string jsonl =
      "{\"type\":\"header\",\"schemaVersion\":1,\"sampleRateHz\":60,"
      "\"targetType\":\"window\",\"width\":800,\"height\":600,\"originX\":0,"
      "\"originY\":0}\r\n"
      "{\"type\":\"sample\",\"tMs\":0,\"x\":1,\"y\":2,\"visible\":true}\r\n";
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  EXPECT_EQ(data->target_type, "window");  // trailing \r must not corrupt it
  ASSERT_EQ(data->samples.size(), 1u);
  EXPECT_TRUE(data->samples[0].visible);  // bool as last field, before }\r
}

TEST(CursorSidecarReaderTest, SkipsOutOfRangeIntegerSample) {
  const std::string jsonl =
      Header() +
      "{\"type\":\"sample\",\"tMs\":0,\"x\":99999999999999999999,\"y\":2,"
      "\"visible\":true}\n"
      "{\"type\":\"sample\",\"tMs\":10,\"x\":3,\"y\":4,\"visible\":true}\n";
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  // The overflowing-x line is dropped (not wrapped to a garbage position).
  ASSERT_EQ(data->samples.size(), 1u);
  EXPECT_EQ(data->samples[0].x, 3);
}

TEST(SampleCursorAtTest, HandlesEqualAdjacentTimestamps) {
  // Two samples at the same t_ms (the writer doesn't dedupe) — the division
  // guard must not divide by zero; snap to one of them.
  std::vector<CursorSidecarSample> samples = {
      {0, 0, 0, true}, {100, 10, 10, true}, {100, 20, 20, true}, {200, 30, 30, true}};
  const auto at = SampleCursorAt(samples, 100);
  EXPECT_TRUE(at.has);
  EXPECT_TRUE(at.visible);
  EXPECT_DOUBLE_EQ(at.x, 10.0);  // exact match returns the first >= sample
}

TEST(CursorSidecarReaderTest, SortsSamplesByTime) {
  const std::string jsonl =
      Header() +
      "{\"type\":\"sample\",\"tMs\":50,\"x\":5,\"y\":5,\"visible\":true}\n"
      "{\"type\":\"sample\",\"tMs\":10,\"x\":1,\"y\":1,\"visible\":true}\n";
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  ASSERT_EQ(data->samples.size(), 2u);
  EXPECT_EQ(data->samples[0].t_ms, 10);
  EXPECT_EQ(data->samples[1].t_ms, 50);
}

// === Time interpolation (frame-timestamp alignment) ========================

std::vector<CursorSidecarSample> Track() {
  return {{0, 0, 0, true}, {100, 100, 200, true}, {200, 100, 200, false}};
}

TEST(SampleCursorAtTest, EmptyHasNothing) {
  EXPECT_FALSE(SampleCursorAt({}, 5).has);
}

TEST(SampleCursorAtTest, ClampsBeforeFirstAndAfterLast) {
  const auto before = SampleCursorAt(Track(), -50);
  EXPECT_TRUE(before.has);
  EXPECT_DOUBLE_EQ(before.x, 0.0);
  const auto after = SampleCursorAt(Track(), 9999);
  EXPECT_TRUE(after.has);
  EXPECT_FALSE(after.visible);  // last sample is hidden.
}

TEST(SampleCursorAtTest, InterpolatesBetweenTwoVisibleSamples) {
  // Halfway between t=0 (0,0) and t=100 (100,200) → (50,100).
  const auto mid = SampleCursorAt(Track(), 50);
  ASSERT_TRUE(mid.has);
  EXPECT_TRUE(mid.visible);
  EXPECT_DOUBLE_EQ(mid.x, 50.0);
  EXPECT_DOUBLE_EQ(mid.y, 100.0);
}

TEST(SampleCursorAtTest, SnapsToNearestAcrossVisibilityBoundary) {
  // Between t=100 (visible) and t=200 (hidden) — never interpolate across the
  // boundary; t=180 is closer to the hidden t=200 → hidden.
  const auto near_hidden = SampleCursorAt(Track(), 180);
  ASSERT_TRUE(near_hidden.has);
  EXPECT_FALSE(near_hidden.visible);
  // t=120 is closer to the visible t=100 → visible at that sample's position.
  const auto near_visible = SampleCursorAt(Track(), 120);
  ASSERT_TRUE(near_visible.has);
  EXPECT_TRUE(near_visible.visible);
  EXPECT_DOUBLE_EQ(near_visible.x, 100.0);
}

// === Placement (canvas mapping + cursorSize scaling) =======================

TEST(ResolveCursorPlacementTest, MapsCaptureLocalIntoContentRect) {
  // Source 1920x1080 placed at content (0,0,1920,1080) → 1:1, scale 1.
  const auto p = ResolveCursorPlacement(/*cap*/ 100, 50, /*content*/ 0, 0, 1920,
                                        1080, /*source*/ 1920, 1080,
                                        /*cursor_size*/ 1.0);
  EXPECT_DOUBLE_EQ(p.canvas_x, 100.0);
  EXPECT_DOUBLE_EQ(p.canvas_y, 50.0);
  EXPECT_DOUBLE_EQ(p.glyph_scale, 1.0);
}

TEST(ResolveCursorPlacementTest, AppliesContentOffsetAndDownscale) {
  // 1920-wide source fit into a 960-wide content rect offset by (80,45) (e.g.
  // letterboxed). Scale = 0.5; a cursor at (200,100) maps to (80+100, 45+50).
  const auto p = ResolveCursorPlacement(200, 100, 80, 45, 960, 540, 1920, 1080,
                                        1.0);
  EXPECT_DOUBLE_EQ(p.canvas_x, 180.0);
  EXPECT_DOUBLE_EQ(p.canvas_y, 95.0);
  EXPECT_DOUBLE_EQ(p.glyph_scale, 0.5);  // glyph scales with the content.
}

TEST(ResolveCursorPlacementTest, CursorSizeScalesTheGlyph) {
  const auto small = ResolveCursorPlacement(0, 0, 0, 0, 1920, 1080, 1920, 1080,
                                            0.5);
  const auto big = ResolveCursorPlacement(0, 0, 0, 0, 1920, 1080, 1920, 1080,
                                          3.0);
  EXPECT_DOUBLE_EQ(small.glyph_scale, 0.5);
  EXPECT_DOUBLE_EQ(big.glyph_scale, 3.0);
  // Position is unaffected by cursor size.
  EXPECT_DOUBLE_EQ(small.canvas_x, big.canvas_x);
}

}  // namespace
}  // namespace clingfy::capture
