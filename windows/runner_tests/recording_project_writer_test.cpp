#include "Capture/recording_project_writer.h"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace clingfy::capture {
namespace {

namespace fs = std::filesystem;

// Each test gets its own isolated temp directory under the OS's
// canonical temp root so concurrent test runs don't clobber each other.
class RecordingProjectWriterTest : public ::testing::Test {
 protected:
  void SetUp() override {
    base_ = fs::temp_directory_path() /
            ("clingfy-test-" +
             std::to_string(::testing::UnitTest::GetInstance()
                                 ->current_test_info()
                                 ->result()
                                 ->test_property_count()));
    fs::create_directories(base_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(base_, ec);
  }

  // Write a placeholder MP4 file the project writer can move into the
  // bundle. Real test MP4 fixtures are unnecessary — the writer only
  // cares that the file exists.
  fs::path WriteFakeMp4(const std::string& name) {
    const fs::path p = base_ / name;
    std::ofstream out(p, std::ios::binary);
    out << "fake mp4 bytes";
    return p;
  }

  fs::path base_;
};

TEST_F(RecordingProjectWriterTest, RejectsEmptySessionId) {
  ProjectWriterInput input;
  input.source_mp4_path = WriteFakeMp4("a.mp4").string();
  input.recordings_root_override = base_.string();
  auto result = WriteRecordingProject(input);
  EXPECT_EQ(result.kind, ProjectWriterErrorKind::kBadInput);
}

TEST_F(RecordingProjectWriterTest, RejectsEmptySourcePath) {
  ProjectWriterInput input;
  input.session_id = "sess-1";
  input.recordings_root_override = base_.string();
  auto result = WriteRecordingProject(input);
  EXPECT_EQ(result.kind, ProjectWriterErrorKind::kBadInput);
}

TEST_F(RecordingProjectWriterTest, ReportsSourceMissingForMissingMp4) {
  ProjectWriterInput input;
  input.session_id = "sess-1";
  input.source_mp4_path = (base_ / "does-not-exist.mp4").string();
  input.recordings_root_override = base_.string();
  auto result = WriteRecordingProject(input);
  EXPECT_EQ(result.kind, ProjectWriterErrorKind::kSourceMissing);
}

TEST_F(RecordingProjectWriterTest, HappyPathCreatesAllExpectedFiles) {
  const auto fake_mp4 = WriteFakeMp4("source.mp4");
  ProjectWriterInput input;
  input.session_id = "sess-happy";
  input.source_mp4_path = fake_mp4.string();
  input.recordings_root_override = base_.string();
  input.width = 1920;
  input.height = 1080;
  input.fps = 60;
  input.frames_received = 300;
  input.audio_samples_written = 200;
  input.created_at_iso8601 = "2026-05-25T12:00:00.000Z";

  auto result = WriteRecordingProject(input);
  ASSERT_EQ(result.kind, ProjectWriterErrorKind::kNone) << result.message;

  const fs::path project_root = result.project_path;
  EXPECT_TRUE(fs::exists(project_root));
  EXPECT_TRUE(fs::exists(project_root / "capture" / "screen.mov"));
  EXPECT_TRUE(fs::exists(project_root / "capture" / "screen.meta.json"));
  EXPECT_TRUE(fs::exists(project_root / "project.json"));
  EXPECT_TRUE(fs::exists(project_root / "post" / "state.json"));

  // The source file was moved into the project bundle — the original
  // path should be gone (renamed by the writer's `fs::rename`).
  EXPECT_FALSE(fs::exists(fake_mp4))
      << "Source MP4 should be moved into the project, not left behind.";
}

TEST_F(RecordingProjectWriterTest, ManifestPinsRequiredKeys) {
  ProjectWriterInput input;
  input.session_id = "sess-manifest";
  input.created_at_iso8601 = "2026-05-25T12:00:00.000Z";
  const std::string manifest = BuildManifestJson(input);

  // We don't pull in a JSON parser for tests, so do substring
  // assertions — the manifest is small and known-shape. Each key
  // missing here would cause Dart's `RecordingProjectRef.open` to
  // throw at the resolution step.
  EXPECT_NE(manifest.find("\"schemaVersion\": 2"), std::string::npos);
  EXPECT_NE(manifest.find("\"projectId\": \"sess-manifest\""),
            std::string::npos);
  EXPECT_NE(manifest.find("\"status\": \"ready\""), std::string::npos)
      << "Manifest status MUST be 'ready' or Dart refuses to open the "
         "project (RecordingProjectManifestError.projectStatusNotOpenable).";
  EXPECT_NE(manifest.find("\"capture/screen.mov\""), std::string::npos);
  EXPECT_NE(manifest.find("\"capture/screen.meta.json\""), std::string::npos);
  EXPECT_NE(manifest.find("\"post/state.json\""), std::string::npos);
  EXPECT_NE(manifest.find("\"2026-05-25T12:00:00.000Z\""), std::string::npos);
}

TEST_F(RecordingProjectWriterTest, ScreenMetaCarriesDiagnostics) {
  ProjectWriterInput input;
  input.session_id = "sess-meta";
  input.width = 2560;
  input.height = 1440;
  input.fps = 30;
  input.frames_received = 1200;
  input.frames_dropped = 4;
  input.audio_samples_written = 60;
  input.mic_active = true;
  input.loopback_active = false;
  const std::string meta = BuildScreenMetaJson(input);
  EXPECT_NE(meta.find("\"width\": 2560"), std::string::npos);
  EXPECT_NE(meta.find("\"height\": 1440"), std::string::npos);
  EXPECT_NE(meta.find("\"framesReceived\": 1200"), std::string::npos);
  EXPECT_NE(meta.find("\"framesDropped\": 4"), std::string::npos);
  EXPECT_NE(meta.find("\"micActive\": true"), std::string::npos);
  EXPECT_NE(meta.find("\"loopbackActive\": false"), std::string::npos);
  EXPECT_NE(meta.find("\"platform\": \"windows\""), std::string::npos);
}

TEST_F(RecordingProjectWriterTest, ScreenMetaCarriesCaptureTargetType) {
  // Default: display capture records targetType "display" and no windowId.
  ProjectWriterInput display_input;
  display_input.session_id = "sess-target-display";
  const std::string display_meta = BuildScreenMetaJson(display_input);
  EXPECT_NE(display_meta.find("\"targetType\": \"display\""),
            std::string::npos);
  EXPECT_EQ(display_meta.find("\"windowId\""), std::string::npos)
      << "display captures must not emit a windowId";

  // Window capture (Phase 7.1) records the type + the HWND-as-int64.
  ProjectWriterInput window_input;
  window_input.session_id = "sess-target-window";
  window_input.target_type = "window";
  window_input.window_id = std::int64_t{123456};
  const std::string window_meta = BuildScreenMetaJson(window_input);
  EXPECT_NE(window_meta.find("\"targetType\": \"window\""), std::string::npos);
  EXPECT_NE(window_meta.find("\"windowId\": 123456"), std::string::npos);

  // Area capture (Phase 7.2) records the type + the crop as sourceBounds.
  ProjectWriterInput area_input;
  area_input.session_id = "sess-target-area";
  area_input.target_type = "area";
  area_input.source_bounds = SourceBounds{40, 30, 800, 600};
  const std::string area_meta = BuildScreenMetaJson(area_input);
  EXPECT_NE(area_meta.find("\"targetType\": \"area\""), std::string::npos);
  EXPECT_NE(area_meta.find("\"sourceBounds\""), std::string::npos);
  EXPECT_NE(area_meta.find("\"x\": 40"), std::string::npos);
  EXPECT_NE(area_meta.find("\"width\": 800"), std::string::npos);
  EXPECT_EQ(area_meta.find("\"windowId\""), std::string::npos)
      << "area captures must not emit a windowId";
}

// === Phase 8.1 cursor sidecar bundling ====================================

TEST_F(RecordingProjectWriterTest, BundlesCursorSidecarWhenEnabled) {
  const auto fake_mp4 = WriteFakeMp4("src.mp4");
  // A streamed cursor.jsonl temp file the writer should move into the bundle.
  const fs::path cursor = base_ / "clingfy_x.cursor.jsonl";
  { std::ofstream o(cursor, std::ios::binary); o << "{\"type\":\"header\"}\n"; }

  ProjectWriterInput input;
  input.session_id = "sess-cursor";
  input.source_mp4_path = fake_mp4.string();
  input.recordings_root_override = base_.string();
  input.cursor_enabled = true;
  input.cursor_sidecar_path = cursor.string();

  auto result = WriteRecordingProject(input);
  ASSERT_EQ(result.kind, ProjectWriterErrorKind::kNone) << result.message;
  const fs::path project_root = result.project_path;
  EXPECT_TRUE(fs::exists(project_root / "capture" / "cursor.jsonl"));
  EXPECT_FALSE(fs::exists(cursor)) << "temp sidecar should be moved, not copied";

  std::ifstream meta_in(project_root / "capture" / "screen.meta.json");
  std::ostringstream meta_ss; meta_ss << meta_in.rdbuf();
  EXPECT_NE(meta_ss.str().find("\"cursorEnabled\": true"), std::string::npos);

  std::ifstream proj_in(project_root / "project.json");
  std::ostringstream proj_ss; proj_ss << proj_in.rdbuf();
  EXPECT_NE(proj_ss.str().find("\"cursorData\": \"capture/cursor.jsonl\""),
            std::string::npos);
}

TEST_F(RecordingProjectWriterTest, NoCursorSidecarWhenDisabled) {
  const auto fake_mp4 = WriteFakeMp4("src.mp4");
  ProjectWriterInput input;
  input.session_id = "sess-nocursor";
  input.source_mp4_path = fake_mp4.string();
  input.recordings_root_override = base_.string();
  input.cursor_enabled = false;  // Phase 7 fallback / no sampler.

  auto result = WriteRecordingProject(input);
  ASSERT_EQ(result.kind, ProjectWriterErrorKind::kNone) << result.message;
  const fs::path project_root = result.project_path;
  EXPECT_FALSE(fs::exists(project_root / "capture" / "cursor.jsonl"));

  std::ifstream meta_in(project_root / "capture" / "screen.meta.json");
  std::ostringstream meta_ss; meta_ss << meta_in.rdbuf();
  EXPECT_NE(meta_ss.str().find("\"cursorEnabled\": false"), std::string::npos);
}

TEST_F(RecordingProjectWriterTest, DowngradesCursorWhenSidecarMissing) {
  // The engine said the sampler ran, but the temp sidecar is gone (e.g. a crash
  // between flush and bundle). The writer must downgrade rather than claim a
  // cursor file that is not there.
  const auto fake_mp4 = WriteFakeMp4("src.mp4");
  ProjectWriterInput input;
  input.session_id = "sess-missing-cursor";
  input.source_mp4_path = fake_mp4.string();
  input.recordings_root_override = base_.string();
  input.cursor_enabled = true;
  input.cursor_sidecar_path = (base_ / "not-there.cursor.jsonl").string();

  auto result = WriteRecordingProject(input);
  ASSERT_EQ(result.kind, ProjectWriterErrorKind::kNone) << result.message;
  const fs::path project_root = result.project_path;
  EXPECT_FALSE(fs::exists(project_root / "capture" / "cursor.jsonl"));
  std::ifstream meta_in(project_root / "capture" / "screen.meta.json");
  std::ostringstream meta_ss; meta_ss << meta_in.rdbuf();
  EXPECT_NE(meta_ss.str().find("\"cursorEnabled\": false"), std::string::npos);
}

// === Phase 9.2 camera bundling ============================================

TEST_F(RecordingProjectWriterTest, BundlesCameraRawAndMetaWhenEnabled) {
  const auto fake_mp4 = WriteFakeMp4("src.mp4");
  // The camera recorder's temp raw .mp4 the writer should move into the bundle.
  const fs::path camera_raw = base_ / "clingfy_x.camera.mp4";
  { std::ofstream o(camera_raw, std::ios::binary); o << "fake camera bytes"; }

  ProjectWriterInput input;
  input.session_id = "sess-cam";
  input.source_mp4_path = fake_mp4.string();
  input.recordings_root_override = base_.string();
  input.camera_enabled = true;
  input.camera_raw_path = camera_raw.string();
  input.camera_meta_json = "{\n  \"version\": 1\n}\n";

  auto result = WriteRecordingProject(input);
  ASSERT_EQ(result.kind, ProjectWriterErrorKind::kNone) << result.message;
  const fs::path project_root = result.project_path;
  EXPECT_TRUE(fs::exists(project_root / "camera" / "raw.mov"));
  EXPECT_TRUE(fs::exists(project_root / "camera" / "camera.meta.json"));
  EXPECT_FALSE(fs::exists(camera_raw)) << "temp raw should be moved, not copied";

  std::ifstream proj_in(project_root / "project.json");
  std::ostringstream proj_ss; proj_ss << proj_in.rdbuf();
  const std::string manifest = proj_ss.str();
  EXPECT_NE(manifest.find("\"rawVideo\": \"camera/raw.mov\""),
            std::string::npos);
  EXPECT_NE(manifest.find("\"metadata\": \"camera/camera.meta.json\""),
            std::string::npos);
}

TEST_F(RecordingProjectWriterTest, OmitsCameraBlockWhenDisabled) {
  const auto fake_mp4 = WriteFakeMp4("src.mp4");
  ProjectWriterInput input;
  input.session_id = "sess-nocam";
  input.source_mp4_path = fake_mp4.string();
  input.recordings_root_override = base_.string();
  input.camera_enabled = false;  // No camera recorded.

  auto result = WriteRecordingProject(input);
  ASSERT_EQ(result.kind, ProjectWriterErrorKind::kNone) << result.message;
  const fs::path project_root = result.project_path;
  EXPECT_FALSE(fs::exists(project_root / "camera"));

  std::ifstream proj_in(project_root / "project.json");
  std::ostringstream proj_ss; proj_ss << proj_in.rdbuf();
  const std::string manifest = proj_ss.str();
  EXPECT_EQ(manifest.find("\"camera\":"), std::string::npos)
      << "a camera-less recording must omit the manifest camera block";
  EXPECT_EQ(manifest.find("camera/raw.mov"), std::string::npos);
}

TEST_F(RecordingProjectWriterTest, DowngradesCameraWhenRawMissing) {
  // The engine flagged the camera enabled, but the temp raw is gone. The writer
  // must omit the camera block rather than point at a file that is not there.
  const auto fake_mp4 = WriteFakeMp4("src.mp4");
  ProjectWriterInput input;
  input.session_id = "sess-missing-cam";
  input.source_mp4_path = fake_mp4.string();
  input.recordings_root_override = base_.string();
  input.camera_enabled = true;
  input.camera_raw_path = (base_ / "not-there.camera.mp4").string();
  input.camera_meta_json = "{}\n";

  auto result = WriteRecordingProject(input);
  ASSERT_EQ(result.kind, ProjectWriterErrorKind::kNone) << result.message;
  const fs::path project_root = result.project_path;
  EXPECT_FALSE(fs::exists(project_root / "camera" / "raw.mov"));
  std::ifstream proj_in(project_root / "project.json");
  std::ostringstream proj_ss; proj_ss << proj_in.rdbuf();
  EXPECT_EQ(proj_ss.str().find("\"camera\":"), std::string::npos);
}

TEST(RecordingProjectWriterFreeFunctions, Iso8601TimestampShape) {
  const auto ts = CurrentIso8601Timestamp();
  // Length is fixed: "YYYY-MM-DDTHH:MM:SS.sssZ" → 24 chars.
  EXPECT_EQ(ts.size(), 24u);
  EXPECT_EQ(ts[4], '-');
  EXPECT_EQ(ts[7], '-');
  EXPECT_EQ(ts[10], 'T');
  EXPECT_EQ(ts[13], ':');
  EXPECT_EQ(ts[16], ':');
  EXPECT_EQ(ts.back(), 'Z');
}

}  // namespace
}  // namespace clingfy::capture
