#include "Capture/recording_project_reader.h"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace clingfy::capture {
namespace {

namespace fs = std::filesystem;

// Programmatic fixture scaffolding — same pattern as
// recording_project_writer_test. Each test gets its own temp directory
// rooted under fs::temp_directory_path() so concurrent runs don't
// clobber each other.
class RecordingProjectReaderTest : public ::testing::Test {
 protected:
  void SetUp() override {
    // testing::TempDir is not portable on Windows GoogleTest builds;
    // use the canonical OS temp root plus a per-test counter.
    base_ = fs::temp_directory_path() /
            (std::string("clingfy-reader-test-") +
             std::to_string(
                 reinterpret_cast<std::uintptr_t>(this)));
    std::error_code ec;
    fs::remove_all(base_, ec);
    fs::create_directories(base_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(base_, ec);
  }

  // Create a complete happy-path bundle. Each call returns the bundle
  // root. Subdirectories + files exist; their bytes are placeholders.
  fs::path MakeHappyBundle() {
    const fs::path root = base_ / "happy.clingfyproj";
    fs::create_directories(root / "capture");
    fs::create_directories(root / "camera");
    fs::create_directories(root / "post");
    WriteFile(root / "project.json", DefaultManifest());
    WriteFile(root / "capture" / "screen.mov", "fake-mp4");
    WriteFile(root / "capture" / "screen.meta.json", DefaultScreenMeta());
    WriteFile(root / "capture" / "cursor.json", "{\"samples\":[]}");
    WriteFile(root / "capture" / "zoom.manual.json", "[]");
    WriteFile(root / "camera" / "raw.mov", "fake-camera-mp4");
    WriteFile(root / "camera" / "meta.json", "{}");
    return root;
  }

  void WriteFile(const fs::path& path, const std::string& text) {
    std::ofstream out(path, std::ios::binary);
    out << text;
  }

  // Default project.json — schemaVersion 2, all referenced paths set.
  static std::string DefaultManifest() {
    return std::string(R"({
  "schemaVersion": 2,
  "projectId": "sess-happy",
  "createdAt": "2026-05-26T10:00:00.000Z",
  "updatedAt": "2026-05-26T10:00:00.000Z",
  "displayName": "sess-happy",
  "status": "ready",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json",
    "cursorData": "capture/cursor.json",
    "zoomManual": "capture/zoom.manual.json"
  },
  "camera": {
    "rawVideo": "camera/raw.mov",
    "metadata": "camera/meta.json",
    "segmentsDirectory": "camera/segments"
  },
  "post": {
    "state": "post/state.json",
    "thumbnail": "post/thumbnail.jpg"
  },
  "derived": {
    "waveform": "derived/waveform.json"
  },
  "exportHistory": []
}
)");
  }

  static std::string DefaultScreenMeta() {
    return std::string(R"({
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "framesReceived": 600,
  "framesDropped": 0,
  "audioSamplesWritten": 240000,
  "micActive": true,
  "loopbackActive": false,
  "platform": "windows"
}
)");
  }

  fs::path base_;
};

// ---- Happy path -----------------------------------------------------

TEST_F(RecordingProjectReaderTest, HappyBundleLoadsAllFields) {
  const fs::path root = MakeHappyBundle();
  const auto result = ReadRecordingProject(root.wstring());

  ASSERT_EQ(result.error, ReadError::kNone) << result.message;
  ASSERT_TRUE(result.project.has_value());
  const auto& p = *result.project;

  EXPECT_EQ(p.project_path, root.wstring());
  EXPECT_EQ(p.schema_version, 2);

  // Required paths land absolute.
  EXPECT_EQ(p.screen_path, (root / "capture" / "screen.mov").wstring());
  EXPECT_EQ(p.screen_metadata_path,
            (root / "capture" / "screen.meta.json").wstring());

  // Optional capture-side assets exist on disk -> set.
  ASSERT_TRUE(p.cursor_path.has_value());
  EXPECT_EQ(*p.cursor_path, (root / "capture" / "cursor.json").wstring());
  ASSERT_TRUE(p.zoom_manual_path.has_value());
  EXPECT_EQ(*p.zoom_manual_path,
            (root / "capture" / "zoom.manual.json").wstring());

  // Camera assets both present -> set.
  ASSERT_TRUE(p.camera_video_path.has_value());
  EXPECT_EQ(*p.camera_video_path, (root / "camera" / "raw.mov").wstring());
  ASSERT_TRUE(p.camera_metadata_path.has_value());

  // Metadata parsed.
  ASSERT_TRUE(p.metadata.has_value());
  EXPECT_EQ(p.metadata->width, 1920u);
  EXPECT_EQ(p.metadata->height, 1080u);
  EXPECT_EQ(p.metadata->fps, 60u);
  EXPECT_EQ(p.metadata->frames_received, 600u);
  EXPECT_EQ(p.metadata->audio_samples_written, 240000u);
  EXPECT_TRUE(p.metadata->mic_active);
  EXPECT_FALSE(p.metadata->loopback_active);
  EXPECT_EQ(p.metadata->platform, "windows");
}

// ---- Missing optional camera / cursor / zoom ------------------------

TEST_F(RecordingProjectReaderTest, MissingCameraIsNotAnError) {
  const fs::path root = MakeHappyBundle();
  // Camera pair must be present-together-or-not-at-all; remove both.
  fs::remove(root / "camera" / "raw.mov");
  fs::remove(root / "camera" / "meta.json");

  const auto result = ReadRecordingProject(root.wstring());
  ASSERT_EQ(result.error, ReadError::kNone) << result.message;
  ASSERT_TRUE(result.project.has_value());
  EXPECT_FALSE(result.project->camera_video_path.has_value());
  EXPECT_FALSE(result.project->camera_metadata_path.has_value());
}

TEST_F(RecordingProjectReaderTest, MissingCursorAndZoomIsNotAnError) {
  const fs::path root = MakeHappyBundle();
  fs::remove(root / "capture" / "cursor.json");
  fs::remove(root / "capture" / "zoom.manual.json");

  const auto result = ReadRecordingProject(root.wstring());
  ASSERT_EQ(result.error, ReadError::kNone) << result.message;
  ASSERT_TRUE(result.project.has_value());
  EXPECT_FALSE(result.project->cursor_path.has_value());
  EXPECT_FALSE(result.project->zoom_manual_path.has_value());
}

TEST_F(RecordingProjectReaderTest,
       PartialCameraPairTriggersRequiredFileMissing) {
  const fs::path root = MakeHappyBundle();
  // Delete the camera metadata but leave raw.mov on disk — broken
  // bundle shape that production must surface.
  fs::remove(root / "camera" / "meta.json");

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kRequiredFileMissing);
  EXPECT_FALSE(result.project.has_value());
}

// ---- Malformed manifest ---------------------------------------------

TEST_F(RecordingProjectReaderTest, MalformedManifestReturnsInvalidJson) {
  const fs::path root = MakeHappyBundle();
  WriteFile(root / "project.json", "{ this is not valid JSON }");

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kManifestInvalidJson);
  EXPECT_FALSE(result.project.has_value());
}

TEST_F(RecordingProjectReaderTest, TruncatedManifestReturnsInvalidJson) {
  const fs::path root = MakeHappyBundle();
  WriteFile(root / "project.json", "{ \"schemaVersion\": 2, \"capture\":");

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kManifestInvalidJson);
}

TEST_F(RecordingProjectReaderTest, NonObjectTopLevelReturnsInvalidJson) {
  const fs::path root = MakeHappyBundle();
  WriteFile(root / "project.json", "[1, 2, 3]");

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kManifestInvalidJson);
}

// ---- Schema version drift -------------------------------------------

TEST_F(RecordingProjectReaderTest, SchemaVersionThreeIsRejected) {
  const fs::path root = MakeHappyBundle();
  std::string manifest = DefaultManifest();
  const auto pos = manifest.find("\"schemaVersion\": 2");
  ASSERT_NE(pos, std::string::npos);
  manifest.replace(pos, std::string("\"schemaVersion\": 2").size(),
                   "\"schemaVersion\": 3");
  WriteFile(root / "project.json", manifest);

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kSchemaVersionMismatch);
  EXPECT_NE(result.message.find("unsupported schemaVersion=3"),
            std::string::npos);
}

TEST_F(RecordingProjectReaderTest, MissingSchemaVersionIsRejected) {
  const fs::path root = MakeHappyBundle();
  std::string manifest = R"({
  "projectId": "sess-x",
  "status": "ready",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json"
  }
}
)";
  WriteFile(root / "project.json", manifest);

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kSchemaVersionMismatch);
}

// ---- Manifest references missing files ------------------------------

TEST_F(RecordingProjectReaderTest,
       MissingScreenVideoTriggersRequiredFileMissing) {
  const fs::path root = MakeHappyBundle();
  fs::remove(root / "capture" / "screen.mov");

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kRequiredFileMissing);
  EXPECT_NE(result.message.find("screen.mov"), std::string::npos);
}

TEST_F(RecordingProjectReaderTest,
       MissingScreenMetaTriggersRequiredFileMissing) {
  const fs::path root = MakeHappyBundle();
  fs::remove(root / "capture" / "screen.meta.json");

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kRequiredFileMissing);
  EXPECT_NE(result.message.find("screen.meta.json"), std::string::npos);
}

TEST_F(RecordingProjectReaderTest,
       ManifestReferencesNonexistentScreenPath) {
  const fs::path root = MakeHappyBundle();
  // Repoint capture.screenVideo at a file that doesn't exist.
  std::string manifest = DefaultManifest();
  const auto pos =
      manifest.find("\"screenVideo\": \"capture/screen.mov\"");
  ASSERT_NE(pos, std::string::npos);
  manifest.replace(
      pos, std::string("\"screenVideo\": \"capture/screen.mov\"").size(),
      "\"screenVideo\": \"capture/does-not-exist.mp4\"");
  WriteFile(root / "project.json", manifest);

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kRequiredFileMissing);
}

// ---- Bundle-not-found cases -----------------------------------------

TEST_F(RecordingProjectReaderTest, NonExistentDirectoryReturnsBundleNotFound) {
  const fs::path root = base_ / "does-not-exist.clingfyproj";
  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kBundleNotFound);
}

TEST_F(RecordingProjectReaderTest, EmptyPathReturnsBundleNotFound) {
  const auto result = ReadRecordingProject(L"");
  EXPECT_EQ(result.error, ReadError::kBundleNotFound);
}

TEST_F(RecordingProjectReaderTest, DirectoryWithoutManifestReturnsBundleNotFound) {
  const fs::path root = base_ / "no-manifest.clingfyproj";
  fs::create_directories(root / "capture");

  const auto result = ReadRecordingProject(root.wstring());
  EXPECT_EQ(result.error, ReadError::kBundleNotFound);
  EXPECT_NE(result.message.find("project.json"), std::string::npos);
}

// ---- Path normalization ---------------------------------------------

TEST_F(RecordingProjectReaderTest, ResolvedPathsAreAbsolute) {
  const fs::path root = MakeHappyBundle();
  const auto result = ReadRecordingProject(root.wstring());
  ASSERT_EQ(result.error, ReadError::kNone) << result.message;
  ASSERT_TRUE(result.project.has_value());
  const auto& p = *result.project;
  EXPECT_TRUE(fs::path(p.screen_path).is_absolute());
  EXPECT_TRUE(fs::path(p.screen_metadata_path).is_absolute());
}

// ---- Direct JSON helpers (no filesystem) ----------------------------

TEST(RecordingProjectReaderJson, ParseManifestJsonAcceptsSchemaTwo) {
  const std::string text = R"({
  "schemaVersion": 2,
  "status": "ready"
}
)";
  const auto result = ParseManifestJson(text);
  EXPECT_EQ(result.error, ReadError::kNone);
  ASSERT_TRUE(result.project.has_value());
  EXPECT_EQ(result.project->schema_version, 2);
}

TEST(RecordingProjectReaderJson, ParseManifestJsonRejectsSchemaDrift) {
  const std::string text = R"({"schemaVersion": 7})";
  const auto result = ParseManifestJson(text);
  EXPECT_EQ(result.error, ReadError::kSchemaVersionMismatch);
}

TEST(RecordingProjectReaderJson,
     ParseManifestJsonRejectsTrailingGarbage) {
  const std::string text =
      R"({"schemaVersion":2,"status":"ready"} not-json-after)";
  const auto result = ParseManifestJson(text);
  EXPECT_EQ(result.error, ReadError::kManifestInvalidJson);
}

TEST(RecordingProjectReaderJson, ParseScreenMetaPopulatesFields) {
  const std::string text =
      R"({"width":640,"height":480,"fps":30,"micActive":false,"platform":"macos"})";
  const auto meta = ParseScreenMetaJson(text);
  ASSERT_TRUE(meta.has_value());
  EXPECT_EQ(meta->width, 640u);
  EXPECT_EQ(meta->height, 480u);
  EXPECT_EQ(meta->fps, 30u);
  EXPECT_FALSE(meta->mic_active);
  EXPECT_EQ(meta->platform, "macos");
}

TEST(RecordingProjectReaderJson, ParseScreenMetaReturnsEmptyOnMalformed) {
  const auto meta = ParseScreenMetaJson("not json");
  EXPECT_FALSE(meta.has_value());
}

}  // namespace
}  // namespace clingfy::capture
