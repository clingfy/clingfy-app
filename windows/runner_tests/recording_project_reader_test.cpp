#include "Capture/recording_project_reader.h"

#include <gtest/gtest.h>

#include "Capture/recording_project_writer.h"  // editorSeed round-trip

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

TEST(RecordingProjectReaderJson, ParseScreenMetaReadsEditorSeed) {
  const std::string text = R"({
    "width": 1920, "height": 1080, "platform": "windows",
    "editorSeed": {
      "cameraVisible": true,
      "cameraLayoutPreset": "overlayBottomRight",
      "cameraShape": "square",
      "cameraCornerRadius": 0.3,
      "cameraOpacity": 0.75,
      "cameraMirror": false,
      "cameraShadow": 3,
      "cameraBorderWidth": 6,
      "cameraBorderColorArgb": 4294967295,
      "cameraChromaKeyEnabled": true,
      "cameraChromaKeyStrength": 0.55,
      "cameraChromaKeyColorArgb": 4278255360,
      "cameraNormalizedCenter": {"x": 0.8, "y": 0.9}
    }
  })";
  const auto meta = ParseScreenMetaJson(text);
  ASSERT_TRUE(meta.has_value());
  ASSERT_TRUE(meta->editor_seed.has_value());
  const CameraEditorSeed& s = *meta->editor_seed;
  EXPECT_TRUE(s.visible);
  EXPECT_EQ(s.layout_preset, "overlayBottomRight");
  EXPECT_EQ(s.shape, "square");
  EXPECT_DOUBLE_EQ(s.corner_radius, 0.3);
  EXPECT_DOUBLE_EQ(s.opacity, 0.75);
  EXPECT_FALSE(s.mirror);
  EXPECT_EQ(s.shadow_preset, 3);
  EXPECT_DOUBLE_EQ(s.border_width, 6.0);
  ASSERT_TRUE(s.border_color_argb.has_value());
  EXPECT_EQ(*s.border_color_argb, 0xFFFFFFFFu);
  EXPECT_TRUE(s.chroma_key_enabled);
  EXPECT_DOUBLE_EQ(s.chroma_key_strength, 0.55);
  ASSERT_TRUE(s.chroma_key_color_argb.has_value());
  EXPECT_EQ(*s.chroma_key_color_argb, 0xFF00FF00u);
  ASSERT_TRUE(s.normalized_center_x.has_value());
  ASSERT_TRUE(s.normalized_center_y.has_value());
  EXPECT_DOUBLE_EQ(*s.normalized_center_x, 0.8);
  EXPECT_DOUBLE_EQ(*s.normalized_center_y, 0.9);
}

TEST(RecordingProjectReaderJson, ParseScreenMetaWithoutEditorSeedLeavesNullopt) {
  const auto meta =
      ParseScreenMetaJson(R"({"width":640,"platform":"windows"})");
  ASSERT_TRUE(meta.has_value());
  EXPECT_FALSE(meta->editor_seed.has_value());
}

// The writer emits the on-disk `camera*` keys and the reader parses them back;
// this pins that they agree (a renamed/typo'd key on either side breaks here)
// AND that std::to_chars doubles + oversized ARGB ints round-trip losslessly.
TEST(RecordingProjectReaderJson, EditorSeedWriterReaderRoundTrip) {
  ProjectWriterInput input;
  input.session_id = "rt";
  CameraEditorSeed seed;
  seed.visible = true;
  seed.layout_preset = "sideBySideLeft";
  seed.shape = "squircle";
  seed.corner_radius = 0.4;
  seed.size_factor = 0.22;
  seed.opacity = 0.9;
  seed.mirror = true;
  seed.content_mode = "fill";
  seed.border_width = 3.5;
  seed.border_color_argb = 0xFF112233u;
  seed.shadow_preset = 1;
  seed.chroma_key_enabled = true;
  seed.chroma_key_strength = 0.35;
  seed.chroma_key_color_argb = 0xFF00AA00u;
  seed.zoom_behavior = "fixed";
  seed.zoom_scale_multiplier = 0.5;
  seed.intro_preset = "pop";
  seed.outro_preset = "slide";
  seed.zoom_emphasis_preset = "pulse";
  seed.intro_duration_ms = 300;
  seed.outro_duration_ms = 250;
  seed.zoom_emphasis_strength = 0.2;
  seed.normalized_center_x = 0.3;
  seed.normalized_center_y = 0.7;
  input.editor_seed = seed;

  const auto meta = ParseScreenMetaJson(BuildScreenMetaJson(input));
  ASSERT_TRUE(meta.has_value());
  ASSERT_TRUE(meta->editor_seed.has_value());
  const CameraEditorSeed& r = *meta->editor_seed;
  EXPECT_EQ(r.visible, seed.visible);
  EXPECT_EQ(r.layout_preset, seed.layout_preset);
  EXPECT_EQ(r.shape, seed.shape);
  EXPECT_DOUBLE_EQ(r.corner_radius, seed.corner_radius);
  EXPECT_DOUBLE_EQ(r.size_factor, seed.size_factor);
  EXPECT_DOUBLE_EQ(r.opacity, seed.opacity);
  EXPECT_EQ(r.mirror, seed.mirror);
  EXPECT_EQ(r.content_mode, seed.content_mode);
  EXPECT_DOUBLE_EQ(r.border_width, seed.border_width);
  EXPECT_EQ(r.border_color_argb, seed.border_color_argb);
  EXPECT_EQ(r.shadow_preset, seed.shadow_preset);
  EXPECT_EQ(r.chroma_key_enabled, seed.chroma_key_enabled);
  EXPECT_DOUBLE_EQ(r.chroma_key_strength, seed.chroma_key_strength);
  EXPECT_EQ(r.chroma_key_color_argb, seed.chroma_key_color_argb);
  EXPECT_EQ(r.zoom_behavior, seed.zoom_behavior);
  EXPECT_DOUBLE_EQ(r.zoom_scale_multiplier, seed.zoom_scale_multiplier);
  EXPECT_EQ(r.intro_preset, seed.intro_preset);
  EXPECT_EQ(r.outro_preset, seed.outro_preset);
  EXPECT_EQ(r.zoom_emphasis_preset, seed.zoom_emphasis_preset);
  EXPECT_EQ(r.intro_duration_ms, seed.intro_duration_ms);
  EXPECT_EQ(r.outro_duration_ms, seed.outro_duration_ms);
  EXPECT_DOUBLE_EQ(r.zoom_emphasis_strength, seed.zoom_emphasis_strength);
  ASSERT_TRUE(r.normalized_center_x.has_value());
  ASSERT_TRUE(r.normalized_center_y.has_value());
  EXPECT_DOUBLE_EQ(*r.normalized_center_x, *seed.normalized_center_x);
  EXPECT_DOUBLE_EQ(*r.normalized_center_y, *seed.normalized_center_y);
}


// === Phase 10.4: status gate + recovery-sweep probe =========================

TEST(RecordingProjectReaderStatus, CapturingStatusIsNotOpenable) {
  const auto result = ParseManifestJson(
      "{\"schemaVersion\": 2, \"status\": \"capturing\"}");
  EXPECT_EQ(result.error, ReadError::kProjectNotOpenable);
}

TEST(RecordingProjectReaderStatus, FailedAndCancelledStatusesOpen) {
  for (const char* status : {"ready", "cancelled", "failed"}) {
    const auto result = ParseManifestJson(
        std::string("{\"schemaVersion\": 2, \"status\": \"") + status +
        "\"}");
    EXPECT_EQ(result.error, ReadError::kNone) << status;
    ASSERT_TRUE(result.project.has_value()) << status;
    EXPECT_EQ(result.project->status, status);
  }
}

TEST(RecordingProjectReaderStatus, MissingStatusDefaultsToReady) {
  // Pre-10.4 bundles never carried the key on Windows; they must keep
  // opening.
  const auto result = ParseManifestJson("{\"schemaVersion\": 2}");
  EXPECT_EQ(result.error, ReadError::kNone);
  ASSERT_TRUE(result.project.has_value());
  EXPECT_EQ(result.project->status, "ready");
}

TEST(RecordingProjectReaderStatus, UnknownStatusFailsClosed) {
  const auto result = ParseManifestJson(
      "{\"schemaVersion\": 2, \"status\": \"exploded\"}");
  EXPECT_EQ(result.error, ReadError::kProjectNotOpenable);
}

TEST(RecordingProjectReaderStatus, ProbeIsGateFreeAndTolerant) {
  const auto probe = ProbeManifestStatus(
      "{\"schemaVersion\": 2, \"status\": \"capturing\", "
      "\"projectId\": \"sess-9\", \"ownerPid\": 555}");
  EXPECT_TRUE(probe.parsed);
  EXPECT_EQ(probe.status, "capturing");
  EXPECT_EQ(probe.project_id, "sess-9");
  EXPECT_EQ(probe.owner_pid, 555u);

  const auto sparse = ProbeManifestStatus("{}");
  EXPECT_TRUE(sparse.parsed);
  EXPECT_TRUE(sparse.status.empty());
  EXPECT_EQ(sparse.owner_pid, 0u);

  EXPECT_FALSE(ProbeManifestStatus("not json").parsed);
}

}  // namespace
}  // namespace clingfy::capture
