#include "Capture/Export/export_passthrough.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace clingfy::capture::export_ {
namespace {

namespace fs = std::filesystem;

// ---- ResolveExportDestination ----------------------------------------------
//
// Pure path-arithmetic tests; no filesystem dependency. Validates the
// extension / sanitization / collision-avoidance rules that Slice 1
// commits to.

TEST(ResolveExportDestinationTest, AppendsMovExtensionWhenStemHasNone) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "MyRecording");
  EXPECT_NE(dest.find("MyRecording.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, StripsExistingExtensionThenForcesMov) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "MyRecording.mp4");
  EXPECT_NE(dest.find("MyRecording.mov"), std::string::npos);
  EXPECT_EQ(dest.find(".mp4"), std::string::npos);
}

TEST(ResolveExportDestinationTest, KeepsMultiDotStems) {
  // "first.draft" should NOT have ".draft" treated as an extension —
  // the conservative heuristic strips at most one trailing 1-5 char
  // extension and only when no slashes are present.
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "first.draft");
  EXPECT_NE(dest.find("first.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, KeepsLongTrailingTokenAsPartOfStem) {
  // Trailing token longer than 5 chars is not an extension.
  const std::string dest =
      ResolveExportDestination("C:\\Videos", "Recording.session2026");
  EXPECT_NE(dest.find("Recording.session2026.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, FallsBackToUntitledOnEmptyStem) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "");
  EXPECT_NE(dest.find("Untitled.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, FallsBackToUntitledOnWhitespaceStem) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "   \t ");
  EXPECT_NE(dest.find("Untitled.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, SanitizesForbiddenCharacters) {
  const std::string dest = ResolveExportDestination(
      "C:\\Users\\me\\Videos", "a:b*c?d\"e<f>g|h");
  // The sanitizer operates on the *filename* portion only; the
  // directory portion may legally contain a drive-letter colon (`C:`).
  // Extract the leaf name from the resolved destination and check that
  // every forbidden char is gone there.
  const std::string leaf = fs::u8path(dest).filename().u8string();
  for (char ch : std::string(":*?\"<>|")) {
    EXPECT_EQ(leaf.find(ch), std::string::npos)
        << "Forbidden character '" << ch << "' leaked into filename: "
        << leaf;
  }
  EXPECT_NE(leaf.find(".mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, PreservesSpacesInStem) {
  const std::string dest =
      ResolveExportDestination("C:\\Videos", "My Cool Recording");
  EXPECT_NE(dest.find("My Cool Recording.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, AvoidsCollisionByAppendingNumber) {
  // Stage a file at the resolved location; the next call should land
  // on "(1).mov" rather than overwrite.
  auto tmp = fs::temp_directory_path() / "clingfy_export_collision_test";
  fs::remove_all(tmp);
  fs::create_directories(tmp);

  const std::string staged = (tmp / "Take.mov").u8string();
  std::ofstream(staged) << "marker";
  ASSERT_TRUE(fs::exists(staged));

  const std::string dest =
      ResolveExportDestination(tmp.u8string(), "Take");
  EXPECT_NE(dest.find("Take (1).mov"), std::string::npos)
      << "actual dest: " << dest;

  fs::remove_all(tmp);
}

TEST(ResolveExportDestinationTest, HonorsMp4Format) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "Clip", "mp4");
  EXPECT_NE(dest.find("Clip.mp4"), std::string::npos);
  EXPECT_EQ(dest.find(".mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, DefaultsToMovForMovOrEmpty) {
  EXPECT_NE(
      ResolveExportDestination("C:\\Videos", "Clip", "mov").find("Clip.mov"),
      std::string::npos);
  EXPECT_NE(ResolveExportDestination("C:\\Videos", "Clip").find("Clip.mov"),
            std::string::npos);
}

TEST(ResolveExportDestinationTest, HonorsGifFormat) {
  // Slice 5B: gif resolves to a real .gif path (no longer a .mov fallback).
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "Clip", "gif");
  EXPECT_NE(dest.find("Clip.gif"), std::string::npos);
  EXPECT_EQ(dest.find(".mov"), std::string::npos);
}

// ---- ExportPassthroughCopy (filesystem-touching) ---------------------------
//
// These create a tiny .clingfyproj-shaped scaffold so the project reader
// returns a real screen_path, then verify the copy lands at the expected
// destination.

namespace {
// Unique per-test temp root so the four filesystem tests can't interfere
// with each other when Windows leaves a file lock from a prior run.
fs::path StageProject(const std::string& session_id,
                      const std::string& payload) {
  // Per-session subdir avoids the Windows file-lock race where the
  // previous test's screen.mov hasn't been fully closed by the cmd
  // interpreter yet when the next test starts.
  const auto root = fs::temp_directory_path() /
                    ("clingfy_export_passthrough_test_" + session_id);
  std::error_code ec;
  fs::remove_all(root, ec);
  const auto project = root / (session_id + ".clingfyproj");
  fs::create_directories(project / "capture");

  const std::string manifest = R"({
  "schemaVersion": 2,
  "projectId": ")" + session_id + R"(",
  "createdAt": "2026-05-28T22:00:00.000Z",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json"
  }
})";
  std::ofstream(project / "project.json") << manifest;
  std::ofstream(project / "capture" / "screen.mov") << payload;
  std::ofstream(project / "capture" / "screen.meta.json")
      << R"({"width":1600,"height":900,"fps":30})";
  return project;
}
}  // namespace

TEST(ExportPassthroughCopyTest, CopiesScreenMovToDestination) {
  const auto project = StageProject("export-test-1", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "MyExport";
  input.format = "mov";

  const auto outcome = ExportPassthroughCopy(input);
  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;
  EXPECT_FALSE(outcome.output_path.empty());
  EXPECT_TRUE(fs::exists(fs::u8path(outcome.output_path)));
  EXPECT_FALSE(outcome.format_was_downgraded);

  // Payload survived the copy.
  std::ifstream ifs(fs::u8path(outcome.output_path));
  const std::string content((std::istreambuf_iterator<char>(ifs)),
                             std::istreambuf_iterator<char>());
  EXPECT_EQ(content, "MOCK_VIDEO_BYTES");

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, MovFastCopyIsNotDowngraded) {
  // mov + auto/auto byte-copies and is honored (not a downgrade).
  const auto project = StageProject("export-test-2", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput mov;
  mov.project_path = project.u8string();
  mov.directory_override = dest_dir.u8string();
  mov.format = "mov";
  mov.filename = "MovExport";
  const auto mov_out = ExportPassthroughCopy(mov);
  ASSERT_EQ(mov_out.error, PassthroughError::kNone) << mov_out.message;
  EXPECT_FALSE(mov_out.format_was_downgraded);
  EXPECT_NE(mov_out.output_path.find(".mov"), std::string::npos);

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, GifForcesReencodeNotByteCopy) {
  // Slice 5B: gif resolves to a .gif container, which can never be a byte-copy
  // of the .mov source, so even auto/auto routes through the composition / GIF
  // path. With a non-decodable source that path fails (kRenderFailed) instead
  // of mislabeling a .mov copy as .gif — GPU-independent (device or decode
  // failure both yield kRenderFailed). gif is no longer a downgrade.
  const auto project = StageProject("export-test-gif", "NOT_A_REAL_VIDEO");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput gif;
  gif.project_path = project.u8string();
  gif.directory_override = dest_dir.u8string();
  gif.filename = "GifExport";
  gif.format = "gif";  // auto/auto, no styling -> only the format forces it

  const auto gif_out = ExportPassthroughCopy(gif);
  EXPECT_EQ(gif_out.error, PassthroughError::kRenderFailed) << gif_out.message;
  EXPECT_FALSE(gif_out.format_was_downgraded);

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

// Phase 8.2/8.3: a recording with a cursor sidecar + cursor/zoom enabled (the
// defaults) must take the composition path even for auto/auto .mov (a byte-copy
// can't draw the cursor or apply zoom). Verified GPU-independently: composition
// on a non-decodable source yields kRenderFailed rather than a byte-copy
// (kNone). Staging a cursor.jsonl beside the screen video is what flips it.
void StageCursorSidecar(const fs::path& project) {
  std::ofstream(project / "capture" / "cursor.jsonl")
      << "{\"type\":\"header\",\"schemaVersion\":1,\"sampleRateHz\":60,"
         "\"targetType\":\"display\",\"width\":1600,\"height\":900,"
         "\"originX\":0,\"originY\":0}\n"
         "{\"type\":\"sample\",\"tMs\":0,\"x\":10,\"y\":10,\"visible\":true}\n"
         "{\"type\":\"click\",\"tMs\":50,\"screenX\":10,\"screenY\":10,"
         "\"button\":\"left\",\"action\":\"down\"}\n";
}

TEST(ExportPassthroughCopyTest, CursorOrZoomSidecarForcesReencode) {
  const auto project = StageProject("export-test-sidecar", "NOT_A_REAL_VIDEO");
  StageCursorSidecar(project);
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.format = "mov";  // auto/auto: only the sidecar (cursor/zoom) forces it
  input.filename = "SidecarExport";
  // show_cursor / zoom_effect_enabled default to true.

  const auto out = ExportPassthroughCopy(input);
  EXPECT_EQ(out.error, PassthroughError::kRenderFailed)
      << "a cursor/zoom-bearing recording must re-encode, not byte-copy — "
      << out.message;

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, SidecarWithCursorAndZoomOffStaysByteCopy) {
  const auto project = StageProject("export-test-sidecar-off", "MOCK_BYTES");
  StageCursorSidecar(project);
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.format = "mov";
  input.filename = "NoEffects";
  input.show_cursor = false;          // both effects off → sidecar unused →
  input.zoom_effect_enabled = false;  // the byte-copy fast-path survives.

  const auto out = ExportPassthroughCopy(input);
  ASSERT_EQ(out.error, PassthroughError::kNone) << out.message;
  EXPECT_TRUE(fs::exists(fs::u8path(out.output_path)));
  std::ifstream ifs(fs::u8path(out.output_path));
  const std::string content((std::istreambuf_iterator<char>(ifs)),
                            std::istreambuf_iterator<char>());
  EXPECT_EQ(content, "MOCK_BYTES") << "expected a byte-for-byte copy";

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, Mp4ForcesReencodeNotByteCopy) {
  // An mp4 output can't be a byte-copy of the .mov source, so even auto/auto
  // must route through the re-encode path. With a non-decodable source that
  // path fails (kRenderFailed) instead of byte-copying a mislabeled .mp4 —
  // GPU-independent (device or decode failure both yield kRenderFailed).
  const auto project = StageProject("export-test-mp4", "NOT_A_REAL_VIDEO");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "MyExport";
  input.format = "mp4";  // auto/auto, no styling -> only the format forces it

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_EQ(outcome.error, PassthroughError::kRenderFailed) << outcome.message;

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, CancelledBeforeWorkReturnsCancelled) {
  const auto project = StageProject("export-test-cancel", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "MyExport";

  // An is_cancelled that returns true immediately short-circuits to a clean
  // kCancelled with a "cancelled" message before any copy/render — GPU-free.
  const auto outcome =
      ExportPassthroughCopy(input, {}, [] { return true; });
  EXPECT_EQ(outcome.error, PassthroughError::kCancelled);
  EXPECT_NE(outcome.message.find("cancel"), std::string::npos);

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, ReturnsInputMissingWhenProjectPathEmpty) {
  PassthroughInput input;
  input.directory_override = "C:\\Videos";
  input.filename = "x";

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_EQ(outcome.error, PassthroughError::kInputMissing);
  EXPECT_FALSE(outcome.message.empty());
}

TEST(ExportPassthroughCopyTest, FallsBackToDefaultSaveFolderWhenDirOverrideEmpty) {
  // Empty directoryOverride no longer fails — it now falls back to the
  // default save folder (mirroring macOS). Point the resolver at a temp
  // dir via the env override so the test never touches the real
  // %USERPROFILE%\Videos\Clingfy.
  const auto fallback_root =
      fs::temp_directory_path() / "clingfy_export_default_folder_test";
  std::error_code ec;
  fs::remove_all(fallback_root, ec);
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER",
                            fallback_root.wstring().c_str());

  const auto project = StageProject("export-test-3", "DEFAULT_FOLDER_BYTES");

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = "";  // user supplied no folder
  input.filename = "FromDefault";

  const auto outcome = ExportPassthroughCopy(input);
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER", nullptr);

  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;
  EXPECT_FALSE(outcome.output_path.empty());
  EXPECT_NE(outcome.output_path.find("clingfy_export_default_folder_test"),
            std::string::npos)
      << "expected output under the default folder, got: "
      << outcome.output_path;
  EXPECT_TRUE(fs::exists(fs::u8path(outcome.output_path)));

  fs::remove_all(fallback_root, ec);
  fs::remove_all(project.parent_path(), ec);
}

TEST(ExportPassthroughCopyTest, ReturnsInputMissingWhenProjectDoesNotExist) {
  PassthroughInput input;
  input.project_path = "C:\\definitely\\not\\a\\real\\project.clingfyproj";
  input.directory_override = fs::temp_directory_path().u8string();
  input.filename = "x";

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_EQ(outcome.error, PassthroughError::kInputMissing);
}

// ---- Phase 9.4 ShouldCompositeCamera ---------------------------------------
//
// Pure gate: the export draws the camera only when ALL conditions hold. The
// integration (real raw.mov decode + D2D draw) is a CI-only heavy test; this
// pins the decision matrix the spec calls out.

TEST(ShouldCompositeCameraTest, DrawsWhenEverythingPasses) {
  EXPECT_TRUE(ShouldCompositeCamera(/*visible=*/true, /*assets=*/true,
                                    /*meta_parsed=*/true,
                                    /*preview_burned_in=*/false,
                                    /*frames=*/900));
}

TEST(ShouldCompositeCameraTest, SkipsWhenPreviewBurnedIn) {
  // The live preview was already in screen.mov → drawing again doubles it.
  EXPECT_FALSE(ShouldCompositeCamera(true, true, true,
                                     /*preview_burned_in=*/true, 900));
}

TEST(ShouldCompositeCameraTest, SkipsWhenCameraHidden) {
  EXPECT_FALSE(ShouldCompositeCamera(/*visible=*/false, true, true, false, 900));
}

TEST(ShouldCompositeCameraTest, SkipsWhenNoAssets) {
  EXPECT_FALSE(
      ShouldCompositeCamera(true, /*assets=*/false, false, false, 0));
}

TEST(ShouldCompositeCameraTest, SkipsWhenMetaUnparsed) {
  // Assets present but camera.meta.json malformed → meta_parsed=false.
  EXPECT_FALSE(
      ShouldCompositeCamera(true, true, /*meta_parsed=*/false, false, 900));
}

TEST(ShouldCompositeCameraTest, SkipsWhenZeroFrames) {
  // Device lost immediately / never produced a frame.
  EXPECT_FALSE(ShouldCompositeCamera(true, true, true, false, /*frames=*/0));
}

}  // namespace
}  // namespace clingfy::capture::export_
