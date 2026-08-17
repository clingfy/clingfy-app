#include "Capture/Zoom/zoom_manual_store.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace clingfy::capture {
namespace {

ZoomManualSegment Manual(const std::string& id, std::int64_t start,
                         std::int64_t end, const std::string& base = "") {
  ZoomManualSegment s;
  s.id = id;
  s.start_ms = start;
  s.end_ms = end;
  s.source = "manual";
  s.base_id = base;
  return s;
}

// --- the file format, which macOS also reads and writes ---------------------

TEST(ZoomManualStoreTest, RoundTripsThroughTheV2Shape) {
  const std::vector<ZoomManualSegment> in{
      Manual("m1", 1000, 2500),
      Manual("m2", 4000, 4800, "auto_3"),
  };
  const std::vector<ZoomManualSegment> out =
      ParseZoomManualJson(SerializeZoomManualJson(in));

  ASSERT_EQ(out.size(), 2u);
  EXPECT_EQ(out[0].id, "m1");
  EXPECT_EQ(out[0].start_ms, 1000);
  EXPECT_EQ(out[0].end_ms, 2500);
  EXPECT_TRUE(out[0].base_id.empty());
  EXPECT_EQ(out[1].base_id, "auto_3");
}

TEST(ZoomManualStoreTest, ReadsTheExactShapeMacOsWrites) {
  // Pinned as a literal, not round-tripped: this is a CROSS-PLATFORM file, and
  // a project edited on a Mac has to open on Windows. Round-tripping our own
  // writer would pass even if both halves drifted together.
  const std::string macos_json = R"({
    "version" : 2,
    "segments" : [
      { "id" : "seg-a", "startMs" : 120, "endMs" : 3400, "source" : "manual" },
      { "baseId" : "auto_0", "endMs" : 0, "id" : "seg-b", "startMs" : 0,
        "source" : "manual" }
    ]
  })";
  const auto out = ParseZoomManualJson(macos_json);
  ASSERT_EQ(out.size(), 2u);
  EXPECT_EQ(out[0].id, "seg-a");
  EXPECT_EQ(out[0].start_ms, 120);
  EXPECT_EQ(out[0].end_ms, 3400);
  EXPECT_EQ(out[1].base_id, "auto_0");
  EXPECT_TRUE(IsZoomTombstone(out[1]));
}

TEST(ZoomManualStoreTest, MissingSourceDefaultsToManual) {
  const auto out = ParseZoomManualJson(
      R"({"version":2,"segments":[{"id":"x","startMs":0,"endMs":10}]})");
  ASSERT_EQ(out.size(), 1u);
  EXPECT_EQ(out[0].source, "manual");
}

TEST(ZoomManualStoreTest, MalformedInputLosesEditsRatherThanFailing) {
  // Refusing to open a project because its zoom sidecar is corrupt would be a
  // worse outcome than dropping the edits, so every one of these is empty
  // rather than an error.
  EXPECT_TRUE(ParseZoomManualJson("").empty());
  EXPECT_TRUE(ParseZoomManualJson("not json at all").empty());
  EXPECT_TRUE(ParseZoomManualJson("{\"version\":2}").empty());
  EXPECT_TRUE(ParseZoomManualJson("{\"segments\":").empty());
  // Truncated mid-array: keep what parsed cleanly, drop the rest.
  const auto partial = ParseZoomManualJson(
      R"({"segments":[{"id":"a","startMs":0,"endMs":5},{"id":"b","startM)");
  EXPECT_EQ(partial.size(), 1u);
}

TEST(ZoomManualStoreTest, ASegmentMissingItsBoundsIsDropped) {
  // Not merely invalid — dangerous. A segment defaulting to 0/0 would read as
  // a TOMBSTONE and could silently delete an auto segment.
  const auto out = ParseZoomManualJson(
      R"({"segments":[{"id":"x","source":"manual","baseId":"auto_1"}]})");
  EXPECT_TRUE(out.empty());
}

TEST(ZoomManualStoreTest, UnknownKeysFromANewerWriterAreIgnored) {
  const auto out = ParseZoomManualJson(
      R"({"version":9,"segments":[{"id":"x","startMs":1,"endMs":2,
          "focusMode":"fixedTarget","futureThing":42}]})");
  ASSERT_EQ(out.size(), 1u);
  EXPECT_EQ(out[0].start_ms, 1);
}

// --- the merge rule, which is where the semantics live ----------------------

TEST(MergeZoomSegmentsTest, NoManualEditsLeavesAutoUntouched) {
  const std::vector<ZoomSegment> autos{{0, 1000}, {2000, 3000}};
  const auto merged = MergeZoomSegments(autos, {});
  ASSERT_EQ(merged.size(), 2u);
  EXPECT_EQ(merged[0].start_ms, 0);
  EXPECT_EQ(merged[1].start_ms, 2000);
}

TEST(MergeZoomSegmentsTest, AManualSegmentIsAdded) {
  const std::vector<ZoomSegment> autos{{0, 1000}};
  const auto merged = MergeZoomSegments(autos, {Manual("m", 5000, 6000)});
  ASSERT_EQ(merged.size(), 2u);
  EXPECT_EQ(merged[1].start_ms, 5000);
}

TEST(MergeZoomSegmentsTest, AnOverrideReplacesItsAutoSegment) {
  // The user dragged auto_1's edges. Both must not render — that would show
  // the edit stacked on the thing it edited.
  const std::vector<ZoomSegment> autos{{0, 1000}, {2000, 3000}};
  const auto merged =
      MergeZoomSegments(autos, {Manual("m", 2200, 2800, "auto_1")});
  ASSERT_EQ(merged.size(), 2u);
  EXPECT_EQ(merged[0].start_ms, 0);
  EXPECT_EQ(merged[1].start_ms, 2200);
  EXPECT_EQ(merged[1].end_ms, 2800);
}

TEST(MergeZoomSegmentsTest, ATombstoneDeletesItsAutoSegmentAndRendersNothing) {
  // THE encoding that is easy to get wrong: a zero-length segment is not a
  // zero-length zoom, it is a deletion record. It must remove auto_0 and must
  // never itself reach a renderer.
  const std::vector<ZoomSegment> autos{{0, 1000}, {2000, 3000}};
  const auto merged = MergeZoomSegments(autos, {Manual("t", 0, 0, "auto_0")});
  ASSERT_EQ(merged.size(), 1u);
  EXPECT_EQ(merged[0].start_ms, 2000);
}

TEST(MergeZoomSegmentsTest, AutoIdsArePositionalAndMatchTheQueryOrder) {
  // getZoomSegments hands Dart `auto_<index>` over the SAME ordering. If this
  // ever indexed differently, deleting "auto_2" in the editor would remove
  // some other segment — a silent, confusing wrong answer.
  const std::vector<ZoomSegment> autos{
      {0, 100}, {200, 300}, {400, 500}, {600, 700}};
  const auto merged = MergeZoomSegments(autos, {Manual("t", 0, 0, "auto_2")});
  ASSERT_EQ(merged.size(), 3u);
  EXPECT_EQ(merged[0].start_ms, 0);
  EXPECT_EQ(merged[1].start_ms, 200);
  EXPECT_EQ(merged[2].start_ms, 600);  // auto_2 (400) is the one gone
}

TEST(MergeZoomSegmentsTest, DeletingEverythingYieldsNoZoomNotAllTheAutoOnes) {
  const std::vector<ZoomSegment> autos{{0, 100}, {200, 300}};
  const auto merged = MergeZoomSegments(
      autos, {Manual("t0", 0, 0, "auto_0"), Manual("t1", 0, 0, "auto_1")});
  EXPECT_TRUE(merged.empty());
}

TEST(MergeZoomSegmentsTest, ResultIsSortedByStartTime) {
  // Downstream (ZoomSegmentStateAt, the export controller) walks these in
  // order; an unsorted list would make membership resolve wrongly.
  const std::vector<ZoomSegment> autos{{5000, 6000}};
  const auto merged = MergeZoomSegments(
      autos, {Manual("b", 8000, 9000), Manual("a", 1000, 2000)});
  ASSERT_EQ(merged.size(), 3u);
  EXPECT_EQ(merged[0].start_ms, 1000);
  EXPECT_EQ(merged[1].start_ms, 5000);
  EXPECT_EQ(merged[2].start_ms, 8000);
}

TEST(MergeZoomSegmentsTest, AnOverrideForAnAutoIdThatNoLongerExistsIsHarmless) {
  // The recording's auto segments can change (a re-analysis, a different
  // build). An edit referring to a vanished id must still contribute its own
  // segment rather than being dropped or crashing.
  const std::vector<ZoomSegment> autos{{0, 1000}};
  const auto merged =
      MergeZoomSegments(autos, {Manual("m", 4000, 5000, "auto_99")});
  ASSERT_EQ(merged.size(), 2u);
  EXPECT_EQ(merged[1].start_ms, 4000);
}

TEST(ZoomManualSidecarPathTest, LandsInTheCaptureDirectoryBesideTheOthers) {
  EXPECT_EQ(ZoomManualSidecarPath(L"C:\\proj\\a.clingfyproj"),
            L"C:\\proj\\a.clingfyproj\\capture\\zoom.manual.json");
  // Tolerates a trailing separator rather than producing a doubled one.
  EXPECT_EQ(ZoomManualSidecarPath(L"C:\\proj\\a.clingfyproj\\"),
            L"C:\\proj\\a.clingfyproj\\capture\\zoom.manual.json");
  EXPECT_TRUE(ZoomManualSidecarPath(L"").empty());
}

}  // namespace
}  // namespace clingfy::capture
