#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

#include "Bridge/method_router.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

namespace fs = std::filesystem;
using test_support::MakeRecorder;
using test_support::RecordedReply;

// Phase 10.3 honest-UI sweep: getZoomSegments / getStorageSnapshot /
// clearCachedRecordings are REAL. These pin the contracts against
// sandboxed fixtures (CLINGFY_RECORDINGS_ROOT env seam).

RecordedReply DispatchWith(MethodRouter& router, const std::string& method,
                           flutter::EncodableMap args) {
  RecordedReply reply;
  router.Dispatch(
      flutter::MethodCall<flutter::EncodableValue>(
          method, std::make_unique<flutter::EncodableValue>(std::move(args))),
      MakeRecorder(reply));
  return reply;
}

RecordedReply DispatchBare(MethodRouter& router, const std::string& method) {
  RecordedReply reply;
  router.Dispatch(flutter::MethodCall<flutter::EncodableValue>(
                      method, std::make_unique<flutter::EncodableValue>()),
                  MakeRecorder(reply));
  return reply;
}

void WriteTextFile(const fs::path& path, const std::string& text) {
  fs::create_directories(path.parent_path());
  std::ofstream f(path, std::ios::out | std::ios::binary);
  f << text;
}

class StorageZoomTruthTest : public ::testing::Test {
 protected:
  void SetUp() override {
    sandbox_ = fs::temp_directory_path() / L"clingfy_truth_test";
    fs::remove_all(sandbox_);
    fs::create_directories(sandbox_);
    recordings_root_ = sandbox_ / L"recordings";
    fs::create_directories(recordings_root_);
    ::SetEnvironmentVariableW(L"CLINGFY_RECORDINGS_ROOT",
                              recordings_root_.wstring().c_str());
  }
  void TearDown() override {
    ::SetEnvironmentVariableW(L"CLINGFY_RECORDINGS_ROOT", nullptr);
    std::error_code ec;
    fs::remove_all(sandbox_, ec);
  }

  // A minimal-but-valid project bundle whose cursor sidecar produces at
  // least one auto-zoom segment (one click inside a sampled span).
  fs::path WriteProjectWithSidecar() {
    const fs::path root = recordings_root_ / L"proj_zoom";
    WriteTextFile(root / "project.json", R"({
  "schemaVersion": 2,
  "projectId": "sess-zoom",
  "createdAt": "2026-06-10T10:00:00.000Z",
  "updatedAt": "2026-06-10T10:00:00.000Z",
  "displayName": "sess-zoom",
  "status": "ready",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json",
    "cursorData": "capture/cursor.jsonl"
  },
  "exportHistory": []
}
)");
    WriteTextFile(root / "capture" / "screen.mov", "fake-mp4");
    WriteTextFile(root / "capture" / "screen.meta.json",
                  R"({"width":1920,"height":1080,"fps":30,)"
                  R"("framesReceived":90,"framesDropped":0,)"
                  R"("audioSamplesWritten":0,"micActive":false,)"
                  R"("loopbackActive":false,"platform":"windows"})");
    std::string sidecar =
        "{\"type\":\"header\",\"schemaVersion\":1,\"sampleRateHz\":60,"
        "\"targetType\":\"display\",\"width\":1920,\"height\":1080,"
        "\"originX\":0,\"originY\":0}\n";
    for (int t = 0; t <= 5000; t += 100) {
      sidecar += "{\"type\":\"sample\",\"tMs\":" + std::to_string(t) +
                 ",\"x\":100,\"y\":100,\"visible\":true}\n";
    }
    sidecar +=
        "{\"type\":\"click\",\"tMs\":1000,\"button\":\"left\","
        "\"action\":\"down\"}\n";
    WriteTextFile(root / "capture" / "cursor.jsonl", sidecar);
    return root;
  }

  fs::path sandbox_;
  fs::path recordings_root_;
};

TEST_F(StorageZoomTruthTest, GetZoomSegmentsReturnsAutoSegmentsInMacShape) {
  const fs::path project = WriteProjectWithSidecar();
  MethodRouter router;
  const RecordedReply reply = DispatchWith(
      router, "getZoomSegments",
      flutter::EncodableMap{
          {flutter::EncodableValue("projectPath"),
           flutter::EncodableValue(project.string())},
      });

  ASSERT_TRUE(reply.success_called);
  const auto* list = std::get_if<flutter::EncodableList>(&reply.success_value);
  ASSERT_NE(list, nullptr);
  // The click at 1000ms inside the sampled span must yield ≥1 segment —
  // the same list the export's ZoomExportController would build.
  ASSERT_FALSE(list->empty());
  const auto* seg = std::get_if<flutter::EncodableMap>(&(*list)[0]);
  ASSERT_NE(seg, nullptr);
  const auto id = seg->find(flutter::EncodableValue("id"));
  ASSERT_NE(id, seg->end());
  EXPECT_EQ(std::get<std::string>(id->second), "auto_0");
  const auto source = seg->find(flutter::EncodableValue("source"));
  ASSERT_NE(source, seg->end());
  EXPECT_EQ(std::get<std::string>(source->second), "auto");
  const auto start = seg->find(flutter::EncodableValue("startMs"));
  const auto end = seg->find(flutter::EncodableValue("endMs"));
  ASSERT_NE(start, seg->end());
  ASSERT_NE(end, seg->end());
  EXPECT_LT(std::get<std::int64_t>(start->second),
            std::get<std::int64_t>(end->second));
}

TEST_F(StorageZoomTruthTest, GetZoomSegmentsWithoutSidecarReturnsEmpty) {
  const fs::path project = WriteProjectWithSidecar();
  std::error_code ec;
  fs::remove(project / "capture" / "cursor.jsonl", ec);
  MethodRouter router;
  const RecordedReply reply = DispatchWith(
      router, "getZoomSegments",
      flutter::EncodableMap{
          {flutter::EncodableValue("projectPath"),
           flutter::EncodableValue(project.string())},
      });
  ASSERT_TRUE(reply.success_called);
  const auto* list = std::get_if<flutter::EncodableList>(&reply.success_value);
  ASSERT_NE(list, nullptr);
  EXPECT_TRUE(list->empty());
}

TEST_F(StorageZoomTruthTest, StorageSnapshotReportsRealBytesAndThresholds) {
  WriteTextFile(recordings_root_ / L"proj_a" / "capture" / "screen.mov",
                std::string(1024, 'x'));
  MethodRouter router;
  const RecordedReply reply = DispatchBare(router, "getStorageSnapshot");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  auto int64_of = [&](const char* key) {
    const auto it = map->find(flutter::EncodableValue(key));
    EXPECT_NE(it, map->end()) << key;
    return it == map->end() ? int64_t{-1} : std::get<int64_t>(it->second);
  };
  // Real volume numbers, not the old zero-fill.
  EXPECT_GT(int64_of("systemTotalBytes"), 0);
  EXPECT_GT(int64_of("systemAvailableBytes"), 0);
  // The sandboxed recordings root holds exactly our 1 KiB fixture.
  EXPECT_EQ(int64_of("recordingsBytes"), 1024);
  // macOS-parity thresholds: 20 GiB warning / 10 GiB critical.
  EXPECT_EQ(int64_of("warningThresholdBytes"),
            int64_t{20} * 1024 * 1024 * 1024);
  EXPECT_EQ(int64_of("criticalThresholdBytes"),
            int64_t{10} * 1024 * 1024 * 1024);
  const auto path_it = map->find(flutter::EncodableValue("recordingsPath"));
  ASSERT_NE(path_it, map->end());
  EXPECT_FALSE(std::get<std::string>(path_it->second).empty());
}

TEST_F(StorageZoomTruthTest, ClearCachedRecordingsDeletesProjectBundlesOnly) {
  WriteTextFile(recordings_root_ / L"sess_a.clingfyproj" / "project.json",
                "{}");
  WriteTextFile(recordings_root_ / L"sess_b.clingfyproj" / "project.json",
                "{}");
  // Foreign content in the root must SURVIVE — the macOS-parity
  // .clingfyproj extension filter is what keeps a stale
  // CLINGFY_RECORDINGS_ROOT override from becoming recursive deletion of
  // arbitrary user data.
  WriteTextFile(recordings_root_ / L"not_a_project" / "keep.txt", "keep");
  WriteTextFile(recordings_root_ / L"stray.txt", "keep me");

  MethodRouter router;
  const RecordedReply reply = DispatchBare(router, "clearCachedRecordings");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);
  const auto it = map->find(flutter::EncodableValue("deletedCount"));
  ASSERT_NE(it, map->end());
  EXPECT_EQ(std::get<int32_t>(it->second), 2);
  EXPECT_FALSE(fs::exists(recordings_root_ / L"sess_a.clingfyproj"));
  EXPECT_FALSE(fs::exists(recordings_root_ / L"sess_b.clingfyproj"));
  EXPECT_TRUE(fs::exists(recordings_root_ / L"not_a_project" / "keep.txt"));
  EXPECT_TRUE(fs::exists(recordings_root_ / L"stray.txt"));
}

}  // namespace
}  // namespace clingfy::bridge
