#include "Capture/Export/export_passthrough.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "Encoding/audio_sidecar_writer.h"

namespace clingfy::capture::export_ {
namespace {

namespace fs = std::filesystem;

// ---- ShouldRetryExportAfterDeviceRemoved ------------------------------------
//
// Pure decision tests; no GPU, no filesystem. Pins the standby-resume retry
// gate: exactly one retry, only for a device-removed render failure, never
// after a cancel request.

PassthroughResult MakeOutcome(PassthroughError error, bool device_removed) {
  PassthroughResult out;
  out.error = error;
  out.device_removed = device_removed;
  return out;
}

TEST(ShouldRetryExportAfterDeviceRemovedTest,
     RetriesFirstDeviceRemovedRenderFailure) {
  EXPECT_TRUE(ShouldRetryExportAfterDeviceRemoved(
      MakeOutcome(PassthroughError::kRenderFailed, /*device_removed=*/true),
      /*attempts_so_far=*/1, /*cancel_requested=*/false));
}

TEST(ShouldRetryExportAfterDeviceRemovedTest, NeverRetriesASecondTime) {
  EXPECT_FALSE(ShouldRetryExportAfterDeviceRemoved(
      MakeOutcome(PassthroughError::kRenderFailed, /*device_removed=*/true),
      /*attempts_so_far=*/2, /*cancel_requested=*/false));
}

TEST(ShouldRetryExportAfterDeviceRemovedTest, NeverRetriesAfterCancelRequest) {
  // A cancel can land in the gap between the failed attempt and the retry —
  // the user's cancel must win over the recovery.
  EXPECT_FALSE(ShouldRetryExportAfterDeviceRemoved(
      MakeOutcome(PassthroughError::kRenderFailed, /*device_removed=*/true),
      /*attempts_so_far=*/1, /*cancel_requested=*/true));
}

TEST(ShouldRetryExportAfterDeviceRemovedTest,
     RenderFailureWithoutDeviceLossIsNotRetried) {
  // A generic render failure (bad source, unsupported media type) would
  // fail again identically — retrying just doubles the wait to the error.
  EXPECT_FALSE(ShouldRetryExportAfterDeviceRemoved(
      MakeOutcome(PassthroughError::kRenderFailed, /*device_removed=*/false),
      /*attempts_so_far=*/1, /*cancel_requested=*/false));
}

TEST(ShouldRetryExportAfterDeviceRemovedTest, OtherOutcomesNeverRetry) {
  for (const auto error :
       {PassthroughError::kNone, PassthroughError::kInputMissing,
        PassthroughError::kNoDestination, PassthroughError::kCopyFailed,
        PassthroughError::kDiskFull, PassthroughError::kCancelled}) {
    // device_removed=true is inconsistent with these outcomes, but the gate
    // must be strict on kRenderFailed regardless.
    EXPECT_FALSE(ShouldRetryExportAfterDeviceRemoved(
        MakeOutcome(error, /*device_removed=*/true),
        /*attempts_so_far=*/1, /*cancel_requested=*/false));
  }
}

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

// Audio separation (design D7/D8): the byte-copy gate. A recording whose
// manifest names a DECODABLE mic/system sidecar must take the composition
// path even for identity auto/auto .mov — a byte-copy would ship the
// embedded premix and silently ignore mic-only gain/normalize (the
// passthrough landmine). An UNDECODABLE sidecar (crash-truncated / junk)
// fails the decode-one-sample probe and cleanly keeps the fast-path.

// Rewrite the staged manifest with the macOS `capture.micAudio` key.
void AddMicSidecarToManifest(const fs::path& project,
                             const std::string& session_id) {
  const std::string manifest = R"({
  "schemaVersion": 2,
  "projectId": ")" + session_id + R"(",
  "createdAt": "2026-05-28T22:00:00.000Z",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json",
    "micAudio": "capture/mic.m4a"
  }
})";
  std::ofstream(project / "project.json") << manifest;
}

TEST(ExportPassthroughCopyTest, DecodableAudioSidecarForcesReencode) {
  const auto project = StageProject("export-test-sep-audio", "NOT_A_REAL_VIDEO");
  AddMicSidecarToManifest(project, "export-test-sep-audio");

  // Produce the sidecar the exact production way: real AAC written to a
  // .mp4 temp, then renamed to capture/mic.m4a (the D2 bundle move) — so
  // this also pins that the probe opens MPEG-4 audio under the .m4a name.
  const fs::path tmp = project / "capture" / "mic.tmp.mp4";
  {
    clingfy::encoding::AudioSidecarWriter writer;
    if (auto err = writer.Open(tmp.string())) {
      GTEST_SKIP() << "AAC sink writer unavailable: " << err->message;
    }
    std::vector<std::int16_t> packet(480 * 2, 1200);
    std::int64_t ts = 0;
    for (int i = 0; i < 10; ++i) {
      ASSERT_FALSE(writer.WriteSamples(packet.data(), 480, ts).has_value());
      ts += 100'000;
    }
    ASSERT_FALSE(writer.Finalize().has_value());
  }
  std::error_code mv_ec;
  fs::rename(tmp, project / "capture" / "mic.m4a", mv_ec);
  ASSERT_FALSE(mv_ec) << mv_ec.message();

  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);
  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.format = "mov";  // identity settings: ONLY the sidecar forces it
  input.filename = "SeparatedExport";
  input.show_cursor = false;
  input.zoom_effect_enabled = false;

  // Composition on the non-decodable screen.mov fails (kRenderFailed) —
  // GPU-independent proof the gate flipped OFF the byte-copy (kNone).
  const auto out = ExportPassthroughCopy(input);
  EXPECT_EQ(out.error, PassthroughError::kRenderFailed)
      << "a separated recording must re-encode, not byte-copy the premix — "
      << out.message;

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, UndecodableAudioSidecarStaysByteCopy) {
  const auto project = StageProject("export-test-sep-junk", "MOCK_BYTES");
  AddMicSidecarToManifest(project, "export-test-sep-junk");
  // The manifest names the sidecar and the file EXISTS, but it's junk — the
  // decode-one-sample probe fails and the legacy fast-path must survive.
  std::ofstream(project / "capture" / "mic.m4a") << "not an mpeg-4 container";

  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);
  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.format = "mov";
  input.filename = "JunkSidecar";
  input.show_cursor = false;
  input.zoom_effect_enabled = false;

  const auto out = ExportPassthroughCopy(input);
  ASSERT_EQ(out.error, PassthroughError::kNone) << out.message;
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

// ---- Phase 10.4 disk-full preflight (pure helpers) --------------------------
//
// The decision + estimate are pure so the EXPORT_DISK_FULL path can be pinned
// with injected values — no need to actually fill a volume.

TEST(ExportDiskPreflightTest, EstimateAddsPassthroughHeadroom) {
  EXPECT_EQ(EstimateRequiredExportBytes(1'000, /*composition=*/false),
            1'000 + kPassthroughDiskHeadroomBytes);
}

TEST(ExportDiskPreflightTest, EstimateAddsLargerCompositionHeadroom) {
  EXPECT_EQ(EstimateRequiredExportBytes(1'000, /*composition=*/true),
            1'000 + kCompositionDiskHeadroomBytes);
  EXPECT_GT(kCompositionDiskHeadroomBytes, kPassthroughDiskHeadroomBytes)
      << "the re-encode path must reserve more than the byte-copy";
}

TEST(ExportDiskPreflightTest, UnknownSourceSizeDisablesTheEstimate) {
  // A failed file_size probe must never block the export (soft-fail).
  EXPECT_EQ(EstimateRequiredExportBytes(-1, false), -1);
  EXPECT_EQ(EstimateRequiredExportBytes(-1, true), -1);
}

TEST(ExportDiskPreflightTest, FitsWhenAvailableCoversRequired) {
  EXPECT_TRUE(ExportDiskPreflightFits(/*required=*/100, /*available=*/100));
  EXPECT_TRUE(ExportDiskPreflightFits(/*required=*/100, /*available=*/101));
}

TEST(ExportDiskPreflightTest, BlocksWhenAvailableIsShort) {
  EXPECT_FALSE(ExportDiskPreflightFits(/*required=*/100, /*available=*/99));
  EXPECT_FALSE(ExportDiskPreflightFits(
      /*required=*/5'000'000'000, /*available=*/0));
}

TEST(ExportDiskPreflightTest, SoftFailsOnUnknownProbes) {
  // Unknown estimate or failed free-space query → never block.
  EXPECT_TRUE(ExportDiskPreflightFits(/*required=*/-1, /*available=*/0));
  EXPECT_TRUE(ExportDiskPreflightFits(/*required=*/0, /*available=*/0));
  EXPECT_TRUE(ExportDiskPreflightFits(/*required=*/100, /*available=*/-1));
}

TEST(ExportDiskPreflightTest, FormatBytesForUserUsesDecimalMbAndGb) {
  // Mirrors the macOS ByteCountFormatter contract: decimal units, GB or MB,
  // unit included. These strings land verbatim in the EXPORT_DISK_FULL
  // details context that Dart re-renders.
  EXPECT_EQ(FormatBytesForUser(1'500'000'000), "1.5 GB");
  EXPECT_EQ(FormatBytesForUser(2'000'000'000), "2.0 GB");
  EXPECT_EQ(FormatBytesForUser(500'000'000), "500.0 MB");
  EXPECT_EQ(FormatBytesForUser(64ll * 1024 * 1024), "67.1 MB");
  EXPECT_EQ(FormatBytesForUser(0), "0.0 MB");
  EXPECT_EQ(FormatBytesForUser(-5), "0.0 MB");  // defensive clamp
}

// ---- Phase 10.4: failed exports leave no file at the destination ------------

TEST(ExportPassthroughCopyTest, RenderFailureLeavesNoFileAtDestination) {
  // Non-decodable source + mp4 forces the composition path, which fails
  // (kRenderFailed) with or without a GPU. Whatever partial output the
  // pipeline may have created must be gone afterwards — the destination is
  // deterministic here because the fresh out dir has no collisions.
  const auto project = StageProject("export-test-fail-clean", "NOT_A_VIDEO");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "FailClean";
  input.format = "mp4";

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_EQ(outcome.error, PassthroughError::kRenderFailed) << outcome.message;
  EXPECT_TRUE(outcome.output_path.empty());
  EXPECT_FALSE(fs::exists(dest_dir / "FailClean.mp4"))
      << "a failed export must not leave a corrupt file at the destination";

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

// ---- Editing port (color): the passthrough disqualifier ---------------------
//
// CRITICAL regression-class guard: before this slice, a graded .mov export
// byte-copied the UNGRADED source and reported success. A non-identity grade
// must force the composition path; the identity grade (and the auto flag
// alone) must keep the fast-path byte-copy alive.

TEST(ExportPassthroughCopyTest, NonIdentityColorGradeForcesReencode) {
  // mov + auto/auto + no styling: ONLY the grade forces composition. With a
  // non-decodable source the composition path fails (kRenderFailed), which is
  // the GPU-independent proof the byte-copy was NOT taken.
  const auto project = StageProject("export-test-grade", "NOT_A_REAL_VIDEO");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "GradedExport";
  input.format = "mov";
  input.color_grade.saturation = -1.0;

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_EQ(outcome.error, PassthroughError::kRenderFailed) << outcome.message;

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, IdentityColorGradeKeepsByteCopy) {
  const auto project = StageProject("export-test-grade-id", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "UngradedExport";
  input.format = "mov";
  input.color_grade = {};  // explicit identity

  const auto outcome = ExportPassthroughCopy(input);
  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;
  EXPECT_TRUE(fs::exists(fs::u8path(outcome.output_path)));

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, AutoFlagWithZeroValuesKeepsByteCopy) {
  // The Swift-parity trap: autoEnabled=true with all-zero numbers is an
  // IDENTITY grade (numbers-only IsIdentity) and must NOT force a re-encode.
  const auto project =
      StageProject("export-test-grade-auto", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "AutoZeroExport";
  input.format = "mov";
  input.color_grade.auto_enabled = true;  // all numeric fields stay 0

  const auto outcome = ExportPassthroughCopy(input);
  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

// ---- Editing port (clips): the gate + bake behavior --------------------------
//
// The export BAKES every real clip edit via the composition path — cut / trim /
// delete-middle (monotonic) AND reorder / overlap (3b-2, per-range source-window
// reads + a decoupled audio stitch). `ClassifyClipEdit` is the pure gate; the
// ExportPassthroughCopy cases verify it's wired in (mock video bytes can't
// decode, so a baked edit surfaces as a render FAILURE — never a silent
// byte-copy; a real render round-trip is covered in export_pipeline_test).

TEST(ClassifyClipEditTest, EmptyIsPassthrough) {
  EXPECT_EQ(ClassifyClipEdit({}), ClipEditKind::kPassthrough);
}

TEST(ClassifyClipEditTest, SingleWholeFromZeroIsPassthrough) {
  EXPECT_EQ(ClassifyClipEdit({clip_planner::ClipKeptRange{0, 12000}}),
            ClipEditKind::kPassthrough);
}

TEST(ClassifyClipEditTest, CoalescableSplitIsPassthrough) {
  // [0,a] + [a,b] merges back to one window from source 0 — not an edit.
  EXPECT_EQ(ClassifyClipEdit({clip_planner::ClipKeptRange{0, 8400},
                              clip_planner::ClipKeptRange{8400, 12000}}),
            ClipEditKind::kPassthrough);
}

TEST(ClassifyClipEditTest, MonotonicMiddleCutIsBake) {
  EXPECT_EQ(ClassifyClipEdit({clip_planner::ClipKeptRange{0, 4000},
                              clip_planner::ClipKeptRange{6000, 10000}}),
            ClipEditKind::kBake);
}

TEST(ClassifyClipEditTest, HeadTrimIsBake) {
  EXPECT_EQ(ClassifyClipEdit({clip_planner::ClipKeptRange{3000, 10000}}),
            ClipEditKind::kBake);
}

TEST(ClassifyClipEditTest, ReorderIsBake) {
  // A later source window placed BEFORE an earlier one (non-monotonic) bakes
  // via the composition path (3b-2 reads each window in timeline order).
  EXPECT_EQ(ClassifyClipEdit({clip_planner::ClipKeptRange{6000, 8000},
                              clip_planner::ClipKeptRange{0, 2000}}),
            ClipEditKind::kBake);
}

TEST(ClassifyClipEditTest, OverlappingRangesAreBake) {
  // source_in-monotonic but NOT disjoint ([0,2000) overlaps [1000,3000)) —
  // baked like any real edit now that 3b-2 reads each source window per-range.
  EXPECT_EQ(ClassifyClipEdit({clip_planner::ClipKeptRange{0, 2000},
                              clip_planner::ClipKeptRange{1000, 3000}}),
            ClipEditKind::kBake);
}

TEST(ExportPassthroughCopyTest, MonotonicClipCutRoutesToComposition) {
  // A real monotonic cut forces the composition path (never a byte-copy of the
  // uncut source). With mock video bytes that path can't decode, so the result
  // is a render failure — the point is it is NOT a silent kNone byte-copy.
  const auto project = StageProject("export-test-clip-cut", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "CutExport";
  input.format = "mov";
  // A real cut: [0,4000] + [6000,10000] (the 4000-6000 gap was removed).
  input.clip_ranges = {clip_planner::ClipKeptRange{0, 4000},
                       clip_planner::ClipKeptRange{6000, 10000}};

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_NE(outcome.error, PassthroughError::kNone)
      << "a monotonic cut must be composited, never byte-copied uncut";
  EXPECT_FALSE(fs::exists(dest_dir / "CutExport.mov"))
      << "the failed composition must leave no output";

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, ReorderedClipsRouteToComposition) {
  // A reordered timeline is no longer refused: it bakes via the composition
  // path (3b-2 reads each source window in timeline order). Mock video bytes
  // can't decode, so this surfaces as a render failure — the point is it is NOT
  // a silent kNone byte-copy of the uncut source.
  const auto project =
      StageProject("export-test-clips-reorder", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "ReorderExport";
  input.format = "mov";
  // Arrange: timeline order B then A — not source-adjacent, never coalesces.
  input.clip_ranges = {clip_planner::ClipKeptRange{6000, 8000},
                       clip_planner::ClipKeptRange{0, 2000}};

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_NE(outcome.error, PassthroughError::kNone)
      << "a reordered timeline must be composited, never byte-copied uncut";
  EXPECT_FALSE(fs::exists(dest_dir / "ReorderExport.mov"))
      << "the failed composition must leave no output";

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, OverlappingClipsRouteToComposition) {
  // Overlapping source windows (source_in-monotonic but not disjoint) bake via
  // the composition path now that 3b-2 reads each source window per-range,
  // rather than being refused. As above, mock bytes surface a render failure.
  const auto project =
      StageProject("export-test-clips-overlap", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "OverlapExport";
  input.format = "mov";
  input.clip_ranges = {clip_planner::ClipKeptRange{0, 2000},
                       clip_planner::ClipKeptRange{1000, 3000}};

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_NE(outcome.error, PassthroughError::kNone)
      << "an overlapping timeline must be composited, never byte-copied uncut";
  EXPECT_FALSE(fs::exists(dest_dir / "OverlapExport.mov"))
      << "the failed composition must leave no output";

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, CoalescableSplitStaysExportable) {
  // A split with nothing deleted ([0,a]+[a,b]) coalesces back to one
  // contiguous window from source 0 — NOT an edit; the export proceeds as a
  // plain byte-copy. (A pure tail-trim is indistinguishable from the full
  // range without the asset duration and is allowed through — documented
  // limitation until step 3.)
  const auto project =
      StageProject("export-test-clips-split", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "SplitExport";
  input.format = "mov";
  input.clip_ranges = {clip_planner::ClipKeptRange{0, 8400},
                       clip_planner::ClipKeptRange{8400, 12000}};

  const auto outcome = ExportPassthroughCopy(input);
  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;
  EXPECT_TRUE(fs::exists(fs::u8path(outcome.output_path)));

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

}  // namespace
}  // namespace clingfy::capture::export_
