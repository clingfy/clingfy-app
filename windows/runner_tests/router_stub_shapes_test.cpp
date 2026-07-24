#include "Bridge/method_router.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <flutter/encodable_value.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <variant>
#include <vector>

#include "Bridge/native_error_codes.h"
#include "Bridge/Routers/export_router.h"
#include "Capture/Export/export_passthrough.h"
#include "Capture/Export/export_session.h"
#include "Capture/Indicator/recording_indicator_controller.h"
#include "Capture/PreRecordingBar/pre_recording_bar_controller.h"
#include "Capture/recording_engine.h"
#include "Capture/windows_selection_state.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

using test_support::MakeCall;
using test_support::MakeCallWithArgs;
using test_support::MakeRecorder;
using test_support::RecordedReply;

// Helper: dispatch `method` with no args and return the recorded reply.
RecordedReply Dispatch(const MethodRouter& router, const std::string& method) {
  RecordedReply reply;
  router.Dispatch(MakeCall(method), MakeRecorder(reply));
  return reply;
}

RecordedReply DispatchWithArgs(const MethodRouter& router,
                               const std::string& method,
                               flutter::EncodableMap args) {
  RecordedReply reply;
  router.Dispatch(MakeCallWithArgs(method, std::move(args)),
                  MakeRecorder(reply));
  return reply;
}

// === Phase 7.1: setAppWindowTarget is a real consumer ======================
//
// It is also listed in the no-op-shape sweep below (no-args → clears → null
// success), but that path never exercises the {windowId} parse. This drives the
// handler end to end: parse the map → store into WindowsSelectionState → read
// back. Covers the int64 codec branch (a real HWND ships as int64), the int32
// branch, and the null-clears path.
TEST(StubShapesTest, SetAppWindowTargetStoresAndClearsWindowId) {
  clingfy::capture::WindowsSelectionState::Instance().ResetForTesting();
  MethodRouter router;

  const auto r_int64 = DispatchWithArgs(
      router, "setAppWindowTarget",
      {{flutter::EncodableValue("windowId"),
        flutter::EncodableValue(std::int64_t{0x1234ABCD})}});
  EXPECT_TRUE(r_int64.success_called);
  EXPECT_FALSE(r_int64.error_called);
  ASSERT_TRUE(
      clingfy::capture::WindowsSelectionState::Instance().AppWindowId());
  EXPECT_EQ(*clingfy::capture::WindowsSelectionState::Instance().AppWindowId(),
            0x1234ABCD);

  // A windowId that arrives as int32 still parses (ReadOptionalInt int32 branch).
  const auto r_int32 = DispatchWithArgs(
      router, "setAppWindowTarget",
      {{flutter::EncodableValue("windowId"),
        flutter::EncodableValue(std::int32_t{777})}});
  EXPECT_TRUE(r_int32.success_called);
  ASSERT_TRUE(
      clingfy::capture::WindowsSelectionState::Instance().AppWindowId());
  EXPECT_EQ(*clingfy::capture::WindowsSelectionState::Instance().AppWindowId(),
            777);

  // No / null windowId clears the selection.
  const auto r_clear =
      DispatchWithArgs(router, "setAppWindowTarget", flutter::EncodableMap{});
  EXPECT_TRUE(r_clear.success_called);
  EXPECT_FALSE(
      clingfy::capture::WindowsSelectionState::Instance().AppWindowId());

  clingfy::capture::WindowsSelectionState::Instance().ResetForTesting();
}

// === Slice 3: setRecordingIndicatorPinned forwards to the controller ========
//
// It parses {pinned: bool} and drives RecordingIndicatorController::SetPinned,
// replying null (the void Dart contract). With no overlay window up in the test
// binary, SetPinned just stores the cached flag — which is exactly the state
// the WM_NCHITTEST / PlaceWindow paths read, so pinned_for_testing() reflects
// the wire value. A missing/garbage `pinned` must not crash and must not flip
// the flag.
TEST(StubShapesTest, SetRecordingIndicatorPinnedForwardsToController) {
  auto& indicator = clingfy::capture::RecordingIndicatorController::Instance();
  MethodRouter router;

  const auto r_true = DispatchWithArgs(
      router, "setRecordingIndicatorPinned",
      {{flutter::EncodableValue("pinned"), flutter::EncodableValue(true)}});
  EXPECT_TRUE(r_true.success_called);
  EXPECT_FALSE(r_true.error_called);
  EXPECT_TRUE(r_true.success_value.IsNull());
  EXPECT_TRUE(indicator.pinned_for_testing());

  const auto r_false = DispatchWithArgs(
      router, "setRecordingIndicatorPinned",
      {{flutter::EncodableValue("pinned"), flutter::EncodableValue(false)}});
  EXPECT_TRUE(r_false.success_called);
  EXPECT_FALSE(indicator.pinned_for_testing());

  // Missing args: still a null success, and the flag is untouched.
  const auto r_missing = DispatchWithArgs(
      router, "setRecordingIndicatorPinned", flutter::EncodableMap{});
  EXPECT_TRUE(r_missing.success_called);
  EXPECT_TRUE(r_missing.success_value.IsNull());
  EXPECT_FALSE(indicator.pinned_for_testing());
}

// === Slice 4: the pre-recording bar methods drive the controller ===========
//
// setPreRecordingBarEnabled / setPreRecordingBarVisible / show / toggle /
// setPreRecordingBarState route to PreRecordingBarController and each reply
// null. Window creation is suppressed so the routing/parse paths run headless
// (no overlay window on the CI agent).
TEST(StubShapesTest, PreRecordingBarMethodsDriveController) {
  auto& bar = clingfy::capture::PreRecordingBarController::Instance();
  bar.set_suppress_window_for_testing(true);
  MethodRouter router;

  // Enabled toggle parses {enabled} and stores it.
  const auto disabled = DispatchWithArgs(
      router, "setPreRecordingBarEnabled",
      {{flutter::EncodableValue("enabled"), flutter::EncodableValue(false)}});
  EXPECT_TRUE(disabled.success_called);
  EXPECT_TRUE(disabled.success_value.IsNull());
  EXPECT_FALSE(bar.enabled_for_testing());

  // setPreRecordingBarVisible shares the handler (mirrors macOS).
  const auto visible = DispatchWithArgs(
      router, "setPreRecordingBarVisible",
      {{flutter::EncodableValue("enabled"), flutter::EncodableValue(true)}});
  EXPECT_TRUE(visible.success_called);
  EXPECT_TRUE(bar.enabled_for_testing());

  // The state feed parses the render subset of the map.
  flutter::EncodableMap state{
      {flutter::EncodableValue("phase"), flutter::EncodableValue(2)},
      {flutter::EncodableValue("targetMode"), flutter::EncodableValue(3)},
      {flutter::EncodableValue("cameraEnabled"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("micEnabled"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("systemAudioEnabled"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("updateAvailable"),
       flutter::EncodableValue(true)},
      {flutter::EncodableValue("canPauseResume"),
       flutter::EncodableValue(true)},
      {flutter::EncodableValue("pauseResumeInFlight"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("countdownActive"),
       flutter::EncodableValue(false)},
  };
  const auto pushed =
      DispatchWithArgs(router, "setPreRecordingBarState", std::move(state));
  EXPECT_TRUE(pushed.success_called);
  EXPECT_TRUE(pushed.success_value.IsNull());
  const clingfy::capture::PreRecordingBarInputs got = bar.inputs_for_testing();
  EXPECT_EQ(got.phase, 2);
  EXPECT_EQ(got.target_mode, 3);
  EXPECT_TRUE(got.camera_selected);
  EXPECT_TRUE(got.mic_enabled);
  EXPECT_FALSE(got.system_audio_enabled);
  EXPECT_TRUE(got.update_available);
  EXPECT_TRUE(got.can_pause_resume);

  // show / toggle just reply null (no window to move while suppressed).
  EXPECT_TRUE(Dispatch(router, "showPreRecordingBar").success_called);
  EXPECT_TRUE(Dispatch(router, "togglePreRecordingBar").success_called);

  bar.set_suppress_window_for_testing(false);
}

// === Phase 7.2/7.3: area selection lifecycle ===============================
//
// pickAreaRecordingRegion is intentionally NOT dispatched here: Phase 7.3 makes
// it launch a modal native overlay with its own message loop, which would hang a
// unit test (no user to drag/cancel). Its selection math is covered by
// area_picker_geometry_test; the modal overlay itself is human-smoke-tested.
// This pins clearAreaRecordingSelection: it clears the stored region and replies
// null. The region is seeded directly (the picker can't run in a test).
TEST(StubShapesTest, ClearAreaRecordingSelectionClearsStoredRegion) {
  clingfy::capture::WindowsSelectionState::Instance().ResetForTesting();
  clingfy::capture::AreaRegion region;
  region.x = 10;
  region.y = 20;
  region.width = 320;
  region.height = 240;
  clingfy::capture::WindowsSelectionState::Instance().SetAreaRegion(region);
  ASSERT_TRUE(clingfy::capture::WindowsSelectionState::Instance()
                  .CurrentAreaRegion()
                  .has_value());

  MethodRouter router;
  const auto cleared = Dispatch(router, "clearAreaRecordingSelection");
  EXPECT_TRUE(cleared.success_called);
  EXPECT_TRUE(cleared.success_value.IsNull());
  EXPECT_FALSE(clingfy::capture::WindowsSelectionState::Instance()
                   .CurrentAreaRegion()
                   .has_value());

  clingfy::capture::WindowsSelectionState::Instance().ResetForTesting();
}

// === Setters return success with no value. =================================

TEST(StubShapesTest, NoopSettersReturnSuccessWithNullValue) {
  MethodRouter router;
  // Sample of methods from each domain that should be no-op success.
  const std::vector<std::string> kSetters = {
      "setRecordingQuality",
      "setFileNameTemplate",
      "setExcludeRecorderApp",
      "setExcludeMicFromSystemAudio",
      "setMicEchoCancellationEnabled",
      "previewSetVoiceCleanup",
      "setCaptureFrameRate",
      "setDisplay",
      "setAppWindowTarget",
      "setDisplayTargetMode",
      "setAudioSource",
      "setVideoSource",
      // updateAudioPreview became REAL in editing step 4-7d (routes to
      // PreviewEngine::SetAudioMix) — its contract test lives below with the
      // other audio-mix methods. setAudioMix/setAudioGainDb stay legacy
      // accepted no-ops.
      "setAudioMix",
      "setAudioGainDb",
      // pickAreaRecordingRegion now returns a region map (Phase 7.2) — covered
      // by its own test below, not the null-shape sweep.
      "revealAreaRecordingRegion",
      "clearAreaRecordingSelection",
      "setOverlayEnabled",
      "setOverlayLinkedToRecording",
      "setOverlayMirror",
      "showCameraOverlay",
      "hideCameraOverlay",
      "setCameraOverlaySize",
      "setCameraOverlayFrame",
      "setCameraOverlayPosition",
      "setCameraOverlayCustomPosition",
      "setCameraOverlayShape",
      "setCameraOverlayRoundness",
      "setCameraOverlayOpacity",
      "setCameraOverlayShadow",
      "setCameraOverlayBorder",
      "setCameraOverlayBorderWidth",
      "setCameraOverlayBorderColor",
      "setCameraOverlayHighlight",
      "setCameraOverlayHighlightStrength",
      "setCursorHighlightEnabled",
      "setCursorHighlightLinkedToRecording",
      "setChromaKeyEnabled",
      "setChromaKeyColor",
      "setChromaKeyStrength",
      // setRecordingIndicatorPinned became REAL in Slice 3 — it forwards to
      // RecordingIndicatorController::SetPinned. Its dedicated contract test is
      // below (SetRecordingIndicatorPinnedForwardsToController).
      // The setPreRecordingBar* / show / toggle methods became REAL in Slice 4
      // — they drive PreRecordingBarController. Their dedicated contract test is
      // below (PreRecordingBarMethodsDriveController); not no-op setters.
      // previewOpen / previewClose / previewPlay / previewPause /
      // previewSeekTo are no longer no-op setters as of Steps 5.3 +
      // 5.5 — they route through PreviewEngine, return BAD_ARGS /
      // PREVIEW_INPUT_MISSING when inputs are wrong, and silently
      // reply null on stale-session calls. Their dedicated contract
      // tests live in preview_router_test.cpp. previewPeekTo stays
      // a no-op setter until a future editor revision needs it.
      "previewPeekTo",
      "playerPlay",
      "playerPause",
      "playerSeekTo",
      "inlinePreviewStop",
      "previewSetCameraPlacement",
      "previewSetZoomSegments",
      // previewSetAudioMix / previewSetAudioGainDb became REAL in editing
      // step 4-7d (PreviewEngine::SetAudioMix aliases) — dedicated contract
      // tests below.
      "openAccessibilitySettings",
      "openScreenRecordingSettings",
      "openSystemSettings",
      "relaunchApp",
      // Phase 10.1: openSaveFolder + the reveal*/log methods are real now —
      // their contract (success/error gating) is pinned in
      // storage_router_reveal_test.cpp.
      "cacheLocalizedStrings",
  };

  for (const auto& method : kSetters) {
    const RecordedReply reply = Dispatch(router, method);
    EXPECT_TRUE(reply.success_called) << "Method '" << method << "' should "
                                         "succeed but did not.";
    EXPECT_FALSE(reply.error_called)
        << "Method '" << method << "' should not error.";
    EXPECT_TRUE(reply.success_value.IsNull())
        << "Method '" << method
        << "' should return null but returned a value.";
  }
}

// === Editing step 4-7d: the audio-mix methods are REAL now =================
//
// updateAudioPreview (the method Dart actually sends) and the
// previewSetAudioMix / previewSetAudioGainDb dispatch aliases route through
// PreviewEngine::SetAudioMix. The engine is idle in runner_tests (never
// Opened), so the stale/no-session path must be a SILENT null success —
// matching macOS ("stale sessionId is a silent success") and the
// previewPlay/Pause precedent above. Args must parse without error for both
// key spellings; a missing-args call must not crash.
TEST(StubShapesTest, AudioMixMethodsReplyNullSuccessWhenNoSessionIsOpen) {
  MethodRouter router;
  const auto dart_keys = DispatchWithArgs(
      router, "updateAudioPreview",
      flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue("rec_stale")},
          {flutter::EncodableValue("gain"), flutter::EncodableValue(6.0)},
          {flutter::EncodableValue("volume"), flutter::EncodableValue(50.0)},
      });
  EXPECT_TRUE(dart_keys.success_called);
  EXPECT_FALSE(dart_keys.error_called);
  EXPECT_TRUE(dart_keys.success_value.IsNull());

  const auto alias_keys = DispatchWithArgs(
      router, "previewSetAudioMix",
      flutter::EncodableMap{
          {flutter::EncodableValue("audioGainDb"),
           flutter::EncodableValue(12.0)},
          {flutter::EncodableValue("audioVolumePercent"),
           flutter::EncodableValue(80.0)},
      });
  EXPECT_TRUE(alias_keys.success_called);
  EXPECT_FALSE(alias_keys.error_called);
  EXPECT_TRUE(alias_keys.success_value.IsNull());

  const auto gain_only = DispatchWithArgs(
      router, "previewSetAudioGainDb",
      flutter::EncodableMap{{flutter::EncodableValue("audioGainDb"),
                             flutter::EncodableValue(24.0)}});
  EXPECT_TRUE(gain_only.success_called);
  EXPECT_FALSE(gain_only.error_called);
  EXPECT_TRUE(gain_only.success_value.IsNull());

  // No args at all: still a tolerated null success (no parse crash).
  const auto no_args = Dispatch(router, "updateAudioPreview");
  EXPECT_TRUE(no_args.success_called);
  EXPECT_FALSE(no_args.error_called);
}

// === Export action methods (Phase 6 Slice 1). ==============================
//
// Phase 3A moved startRecording / stopRecording onto the real
// `RecordingEngine`. Phase 6 Slice 1 lifts `exportVideo` and `processVideo`
// off the NotImplemented stub:
//   - `exportVideo` with no args returns EXPORT_INPUT_MISSING (the project
//     path is required); a happy-path copy is covered in
//     `export_passthrough_test.cpp`.
//   - `processVideo` returns null (no preview file generated; Dart falls
//     back to the raw screen.mov as the preview source). Slices 2+ will
//     produce a real preview path here.

TEST(StubShapesTest, ExportVideoWithoutProjectPathReturnsInputMissing) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "exportVideo");
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kExportInputMissing);
}

TEST(StubShapesTest, ProcessVideoReturnsNullPreviewPath) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "processVideo");
  EXPECT_TRUE(reply.success_called);
  EXPECT_TRUE(reply.success_value.IsNull());
}

// Regression guard: HandleExportVideo's switch must complete the
// MethodResult for EVERY PassthroughError. kRenderFailed — the
// decode -> composite -> re-encode path that Slice 3's padding / corner
// radius / non-auto layout force every styled export through — previously
// had no case and no default, so a render failure fell off the end of the
// switch and left the result un-answered, hanging the Dart `exportVideo`
// future forever (export UI stuck, _isExporting never cleared). This drives
// a real render failure (a valid .clingfyproj whose screen.mov is not a
// decodable video, plus padding>0 to force composition) and asserts the
// call is completed as an EXPORT_ERROR rather than stranded. Works with or
// without a GPU: a missing device fails the render just like a bad source,
// and both surface as kRenderFailed.
TEST(StubShapesTest, ExportVideoRenderFailureRepliesWithExportError) {
  namespace fs = std::filesystem;
  std::error_code ec;
  const auto root = fs::temp_directory_path() / "clingfy_router_render_fail";
  fs::remove_all(root, ec);
  const auto project = root / "render-fail.clingfyproj";
  fs::create_directories(project / "capture");
  const auto out_dir = root / "out";
  fs::create_directories(out_dir);

  std::ofstream(project / "project.json") << R"({
  "schemaVersion": 2,
  "projectId": "render-fail",
  "createdAt": "2026-06-04T00:00:00.000Z",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json"
  }
})";
  // The file exists (so the project reader resolves) but is not a decodable
  // video, so RenderComposedExport fails -> ExportPassthroughCopy returns
  // kRenderFailed.
  std::ofstream(project / "capture" / "screen.mov") << "NOT_A_REAL_VIDEO";
  std::ofstream(project / "capture" / "screen.meta.json")
      << R"({"width":1280,"height":720,"fps":30})";

  MethodRouter router;
  flutter::EncodableMap args{
      {flutter::EncodableValue("projectPath"),
       flutter::EncodableValue(project.u8string())},
      {flutter::EncodableValue("directoryOverride"),
       flutter::EncodableValue(out_dir.u8string())},
      {flutter::EncodableValue("filename"),
       flutter::EncodableValue(std::string("render-fail"))},
      // padding>0 forces the composition path even under an otherwise
      // auto/auto identity transform — the Slice 3 trigger for kRenderFailed.
      {flutter::EncodableValue("padding"), flutter::EncodableValue(10.0)},
  };
  const RecordedReply reply =
      DispatchWithArgs(router, "exportVideo", std::move(args));

  // The defining symptom of the bug was NEITHER callback firing.
  EXPECT_TRUE(reply.success_called || reply.error_called)
      << "exportVideo must always complete the MethodResult — an "
         "un-answered result hangs the Dart export future.";
  EXPECT_TRUE(reply.error_called);
  EXPECT_FALSE(reply.success_called);
  EXPECT_EQ(reply.error_code, error::kExportError);

  fs::remove_all(root, ec);
}

// Regression guard for the Slice 4 "volume default" trap (export_router.cpp /
// export_audio.h flag it as the #1 risk): an exportVideo with NO audio args
// and an auto/auto transform must take the byte-for-byte copy fast-path. If
// audioVolumePercent defaulted to 0 instead of 100, RequiresAudioProcessing
// would read "volume < 100 -> processing requested", force the re-encode path,
// and fail decoding this non-decodable test source. Success proves the absent
// arg defaulted to 100 and stayed on the copy. GPU-independent (the fast-path
// never opens a decoder), which the GPU round-trips can't guarantee on CI.
TEST(StubShapesTest, ExportVideoWithoutAudioArgsTakesCopyFastPath) {
  namespace fs = std::filesystem;
  std::error_code ec;
  const auto root = fs::temp_directory_path() / "clingfy_router_audio_fastpath";
  fs::remove_all(root, ec);
  const auto project = root / "fastpath.clingfyproj";
  fs::create_directories(project / "capture");
  const auto out_dir = root / "out";
  fs::create_directories(out_dir);

  std::ofstream(project / "project.json") << R"({
  "schemaVersion": 2,
  "projectId": "fastpath",
  "createdAt": "2026-06-05T00:00:00.000Z",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json"
  }
})";
  // Non-decodable bytes: the fast-path copy succeeds regardless; only a wrong
  // re-encode (which a volume=0 default would trigger) would fail to decode.
  std::ofstream(project / "capture" / "screen.mov") << "NOT_A_REAL_VIDEO";
  std::ofstream(project / "capture" / "screen.meta.json")
      << R"({"width":1280,"height":720,"fps":30})";

  MethodRouter router;
  flutter::EncodableMap args{
      {flutter::EncodableValue("projectPath"),
       flutter::EncodableValue(project.u8string())},
      {flutter::EncodableValue("directoryOverride"),
       flutter::EncodableValue(out_dir.u8string())},
      {flutter::EncodableValue("filename"),
       flutter::EncodableValue(std::string("fastpath"))},
      // auto/auto, no styling, and crucially NO audio args at all.
      {flutter::EncodableValue("layoutPreset"),
       flutter::EncodableValue(std::string("auto"))},
      {flutter::EncodableValue("resolutionPreset"),
       flutter::EncodableValue(std::string("auto"))},
  };
  const RecordedReply reply =
      DispatchWithArgs(router, "exportVideo", std::move(args));

  EXPECT_TRUE(reply.success_called)
      << "absent audio args must keep the byte-copy fast-path; a volume "
         "default of 0 would force a re-encode that fails here. err="
      << reply.error_code;
  EXPECT_FALSE(reply.error_called);

  fs::remove_all(root, ec);
}

// Slice 5A: cancelExport replies immediately (like macOS `result(nil)`) AND
// flips the shared cancel flag the in-flight export worker polls. (Moved off
// the no-op setter list because it now has a real side effect.)
TEST(StubShapesTest, CancelExportSignalsSessionAndRepliesNull) {
  clingfy::capture::export_::ExportSession::Instance().ResetForTesting();
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "cancelExport");
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
  EXPECT_TRUE(reply.success_value.IsNull());
  EXPECT_TRUE(
      clingfy::capture::export_::ExportSession::Instance().IsCancelled());
  clingfy::capture::export_::ExportSession::Instance().ResetForTesting();
}

// Slice 5A: a second exportVideo while one is already running is rejected with
// BAD_ARGS (the BeginExport reentrancy guard) rather than starting a concurrent
// encoder. GPU-free — the guard fires before any export work, and replies
// synchronously.
TEST(StubShapesTest, ExportVideoWhileAnExportIsRunningReturnsBadArgs) {
  auto& session = clingfy::capture::export_::ExportSession::Instance();
  session.ResetForTesting();
  ASSERT_TRUE(session.BeginExport());  // pretend an export is already running

  MethodRouter router;
  flutter::EncodableMap args{
      {flutter::EncodableValue("projectPath"),
       flutter::EncodableValue(std::string("/some/project.clingfyproj"))},
  };
  const RecordedReply reply =
      DispatchWithArgs(router, "exportVideo", std::move(args));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kBadArgs);

  session.EndExport();
  session.ResetForTesting();
}

// === Phase 10.4: ReplyForExportOutcome contract =============================
//
// The per-outcome error-code mapping is exposed (export_router.h) so these
// can pin the bridge contract without staging a real disk-full volume or a
// mid-export cancel race. The same function runs on both the synchronous and
// the worker-thread reply paths.

// A user cancel replies with the stable EXPORT_CANCELLED code and the fixed
// "Export cancelled." message (previously EXPORT_ERROR + message sniffing).
TEST(StubShapesTest, ReplyForExportOutcomeMapsCancelToExportCancelled) {
  clingfy::capture::export_::PassthroughResult outcome;
  outcome.error = clingfy::capture::export_::PassthroughError::kCancelled;
  outcome.message = "exportVideo: cancelled by user";

  RecordedReply reply;
  const auto recorder = MakeRecorder(reply);
  routers::export_::ReplyForExportOutcome(
      *recorder, outcome, "C:\\p\\x.clingfyproj", "C:\\out");

  EXPECT_FALSE(reply.success_called);
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kExportCancelled);
  EXPECT_EQ(reply.error_message, "Export cancelled.")
      << "the message still contains 'cancelled' so an older Dart "
         "message-classifier also reads it as a clean cancel";
}

// A preflight disk-full replies EXPORT_DISK_FULL with the macOS-shaped
// details map: {stage, reason, context:{tempPath, *TempBytes int64,
// *TempFormatted strings}} — the exact shape ExportPrep.swift emits and
// Dart's ExportDiskFullMessage parses.
TEST(StubShapesTest, ReplyForExportOutcomeDiskFullEmitsMacShapedDetails) {
  clingfy::capture::export_::PassthroughResult outcome;
  outcome.error = clingfy::capture::export_::PassthroughError::kDiskFull;
  outcome.message = "Not enough free disk space to export this recording.";
  outcome.disk_required_bytes = 2'000'000'000;  // 2.0 GB
  outcome.disk_available_bytes = 500'000'000;   // 0.5 GB
  outcome.disk_checked_path = "D:\\Exports";

  RecordedReply reply;
  const auto recorder = MakeRecorder(reply);
  routers::export_::ReplyForExportOutcome(
      *recorder, outcome, "C:\\p\\x.clingfyproj", "D:\\Exports");

  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kExportDiskFull);
  EXPECT_EQ(reply.error_message, outcome.message);

  const auto* details =
      std::get_if<flutter::EncodableMap>(&reply.error_details);
  ASSERT_NE(details, nullptr) << "details must be a map";

  const auto stage_it = details->find(flutter::EncodableValue("stage"));
  ASSERT_NE(stage_it, details->end());
  EXPECT_EQ(std::get<std::string>(stage_it->second), "export_preflight");

  const auto reason_it = details->find(flutter::EncodableValue("reason"));
  ASSERT_NE(reason_it, details->end());
  EXPECT_EQ(std::get<std::string>(reason_it->second), outcome.message);

  const auto context_it = details->find(flutter::EncodableValue("context"));
  ASSERT_NE(context_it, details->end());
  const auto* context = std::get_if<flutter::EncodableMap>(&context_it->second);
  ASSERT_NE(context, nullptr) << "details.context must be a map";

  // Byte counts: int64, shortfall = required - available.
  const auto get_i64 = [context](const char* key) {
    const auto it = context->find(flutter::EncodableValue(key));
    EXPECT_NE(it, context->end()) << "missing context key: " << key;
    return it != context->end() ? std::get<std::int64_t>(it->second)
                                : std::int64_t{-1};
  };
  EXPECT_EQ(get_i64("estimatedRequiredTempBytes"), 2'000'000'000);
  EXPECT_EQ(get_i64("availableTempBytes"), 500'000'000);
  EXPECT_EQ(get_i64("shortfallTempBytes"), 1'500'000'000);

  // Formatted strings: non-empty, GB/MB units — the three keys Dart's
  // ExportDiskFullMessage requires to render the localized message.
  const auto get_str = [context](const char* key) {
    const auto it = context->find(flutter::EncodableValue(key));
    EXPECT_NE(it, context->end()) << "missing context key: " << key;
    return it != context->end() ? std::get<std::string>(it->second)
                                : std::string();
  };
  EXPECT_EQ(get_str("estimatedRequiredTempFormatted"), "2.0 GB");
  EXPECT_EQ(get_str("availableTempFormatted"), "500.0 MB");
  EXPECT_EQ(get_str("shortfallTempFormatted"), "1.5 GB");
  EXPECT_EQ(get_str("tempPath"), "D:\\Exports");
}

// A mid-write disk-full (no preflight estimate) still uses the stable code;
// the context omits the byte counts, so Dart falls back to the
// self-contained native message — which must therefore be non-empty.
TEST(StubShapesTest, ReplyForExportOutcomeMidWriteDiskFullFallsBackToMessage) {
  clingfy::capture::export_::PassthroughResult outcome;
  outcome.error = clingfy::capture::export_::PassthroughError::kDiskFull;
  outcome.message =
      "Not enough free disk space to finish this export — the destination "
      "disk filled up while writing.";
  // disk_required_bytes / disk_available_bytes stay -1 (unknown).
  outcome.disk_checked_path = "D:\\Exports";

  RecordedReply reply;
  const auto recorder = MakeRecorder(reply);
  routers::export_::ReplyForExportOutcome(
      *recorder, outcome, "C:\\p\\x.clingfyproj", "D:\\Exports");

  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kExportDiskFull);
  EXPECT_FALSE(reply.error_message.empty());

  const auto* details =
      std::get_if<flutter::EncodableMap>(&reply.error_details);
  ASSERT_NE(details, nullptr);
  const auto stage_it = details->find(flutter::EncodableValue("stage"));
  ASSERT_NE(stage_it, details->end());
  EXPECT_EQ(std::get<std::string>(stage_it->second), "export_write");
  const auto context_it = details->find(flutter::EncodableValue("context"));
  ASSERT_NE(context_it, details->end());
  const auto* context = std::get_if<flutter::EncodableMap>(&context_it->second);
  ASSERT_NE(context, nullptr);
  EXPECT_EQ(context->find(flutter::EncodableValue(
                "estimatedRequiredTempFormatted")),
            context->end())
      << "an unknown estimate must omit the formatted keys (Dart then falls "
         "back to e.message) rather than send empty strings";
}

// The default: guard must keep completing the MethodResult for any future
// PassthroughError value (an un-answered result hangs the Dart future).
TEST(StubShapesTest, ReplyForExportOutcomeDefaultGuardStillRepliesExportError) {
  clingfy::capture::export_::PassthroughResult outcome;
  outcome.error = static_cast<clingfy::capture::export_::PassthroughError>(999);
  outcome.message.clear();

  RecordedReply reply;
  const auto recorder = MakeRecorder(reply);
  routers::export_::ReplyForExportOutcome(
      *recorder, outcome, "C:\\p\\x.clingfyproj", "C:\\out");

  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kExportError);
  EXPECT_FALSE(reply.error_message.empty());
}

// === Empty-list getters. ===================================================
//
// Phase 2 moved getDisplays / getAppWindows / getAudioSources /
// getVideoSources onto real OS enumerations — the result depends on the host
// machine's monitors, microphones, and cameras and is no longer guaranteed
// to be empty. They are covered by `DeviceListGettersReturnList` below,
// which only asserts the shape (list of maps, with the documented field
// names). The remaining methods here are still Phase-1-style stubs.

TEST(StubShapesTest, ListGettersReturnEmptyList) {
  MethodRouter router;
  const std::vector<std::string> kListGetters = {
      // getZoomSegments is REAL since Phase 10.3 — listed here because
      // an arg-less call (no projectPath) still contracts to [].
      "getZoomSegments",
      "getManualZoomSegments",
  };

  for (const auto& method : kListGetters) {
    const RecordedReply reply = Dispatch(router, method);
    ASSERT_TRUE(reply.success_called)
        << "Method '" << method << "' did not succeed.";
    const auto* list = std::get_if<flutter::EncodableList>(&reply.success_value);
    ASSERT_NE(list, nullptr)
        << "Method '" << method << "' did not return a List.";
    EXPECT_TRUE(list->empty())
        << "Method '" << method << "' should still return an empty list.";
  }
}

// Phase 2 device list-getters: shape only. The host running the tests may
// have zero or many entries; we just want to confirm the dispatcher routes
// the call, the reply is a list, and that any entries present carry the
// documented map keys so the Dart parsers won't crash.

namespace {

void ExpectMapHasStringKeys(const flutter::EncodableMap& map,
                            const std::vector<std::string>& required_keys) {
  for (const auto& key : required_keys) {
    const auto it = map.find(flutter::EncodableValue(key));
    EXPECT_NE(it, map.end()) << "Map is missing required key '" << key << "'.";
  }
}

void ExpectListOfMapsWithKeys(const RecordedReply& reply,
                              const std::string& method,
                              const std::vector<std::string>& keys) {
  ASSERT_TRUE(reply.success_called)
      << "Method '" << method << "' did not succeed.";
  const auto* list =
      std::get_if<flutter::EncodableList>(&reply.success_value);
  ASSERT_NE(list, nullptr)
      << "Method '" << method << "' did not return a List.";
  for (const auto& entry : *list) {
    const auto* entry_map = std::get_if<flutter::EncodableMap>(&entry);
    ASSERT_NE(entry_map, nullptr)
        << "Method '" << method << "' returned a non-map entry.";
    ExpectMapHasStringKeys(*entry_map, keys);
  }
}

}  // namespace

TEST(StubShapesTest, DeviceListGettersReturnList) {
  MethodRouter router;

  ExpectListOfMapsWithKeys(
      Dispatch(router, "getDisplays"), "getDisplays",
      {"id", "name", "x", "y", "width", "height", "scale"});
  ExpectListOfMapsWithKeys(Dispatch(router, "getAppWindows"), "getAppWindows",
                           {"windowId", "appName", "title"});
  ExpectListOfMapsWithKeys(Dispatch(router, "getAudioSources"),
                           "getAudioSources", {"id", "name"});
  ExpectListOfMapsWithKeys(Dispatch(router, "getVideoSources"),
                           "getVideoSources", {"id", "name"});
}

// === Empty-map getters. ====================================================

// Phase 3E and the permissions PR each moved a previously-empty-map
// getter onto a real shape (`getCaptureDiagnostics`,
// `getPermissionStatus`). Both now have their own dedicated shape
// tests further below — `GetCaptureDiagnosticsReportsBackendAndCounters`
// and `GetPermissionStatusReportsFlatBoolMap`. The empty-map block is
// kept around in case a future stub needs the assertion; for now it has
// no inhabitants.

TEST(StubShapesTest, GetPermissionStatusReportsFlatBoolMap) {
  // The Dart parser (`PermissionStatusSnapshot.fromStatusMap`) expects
  // a flat `Map<String, bool>` with these four keys. Screen recording
  // + accessibility are pinned to `true` on Windows (no system gate);
  // mic + camera depend on host privacy settings, so we only assert on
  // the keys and types.
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "getPermissionStatus");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);
  for (const auto& key :
       {"screenRecording", "microphone", "camera", "accessibility"}) {
    const auto it = map->find(flutter::EncodableValue(key));
    ASSERT_NE(it, map->end()) << "Missing key '" << key << "'.";
    EXPECT_NE(std::get_if<bool>(&it->second), nullptr)
        << "Key '" << key << "' must be a bool.";
  }
  const auto screen =
      map->find(flutter::EncodableValue("screenRecording"));
  EXPECT_TRUE(*std::get_if<bool>(&screen->second));
  const auto access = map->find(flutter::EncodableValue("accessibility"));
  EXPECT_TRUE(*std::get_if<bool>(&access->second));
}

TEST(StubShapesTest, RequestScreenRecordingAlwaysGrantedOnWindows) {
  MethodRouter router;
  const RecordedReply reply =
      Dispatch(router, "requestScreenRecordingPermission");
  ASSERT_TRUE(reply.success_called);
  const auto* value = std::get_if<bool>(&reply.success_value);
  ASSERT_NE(value, nullptr);
  EXPECT_TRUE(*value)
      << "Screen recording has no per-app gate on Windows — the request "
         "must always report granted.";
}

TEST(StubShapesTest, IsAccessibilityTrustedAlwaysTrueOnWindows) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "isAccessibilityTrusted");
  ASSERT_TRUE(reply.success_called);
  const auto* value = std::get_if<bool>(&reply.success_value);
  ASSERT_NE(value, nullptr);
  EXPECT_TRUE(*value);
}

TEST(StubShapesTest, OpenSystemSettingsAndRelaunchAreNoopSuccess) {
  // `openSystemSettings` without a pane arg short-circuits inside the
  // handler — `LaunchSettingsUri` rejects the empty URI returned by
  // `ResolveSettingsUri("")`, so no Settings window is launched here.
  // `relaunchApp` is a Phase-10 stub that returns success without side
  // effects. The two `open*Settings` handlers with pinned panes
  // (accessibility / screenRecording) would actually pop a Settings
  // window inside `ctest`, so we cover their URI mapping in
  // `PermissionProbeTest.ResolveSettingsUri*` and leave the side-effect-
  // free routes alone here.
  MethodRouter router;
  for (const auto& method : {"openSystemSettings", "relaunchApp"}) {
    const RecordedReply reply = Dispatch(router, method);
    EXPECT_TRUE(reply.success_called)
        << "Method '" << method << "' should succeed.";
    EXPECT_FALSE(reply.error_called)
        << "Method '" << method << "' should not surface an error.";
  }
}

TEST(StubShapesTest, GetCaptureDiagnosticsReportsBackendAndCounters) {
  // Reset the singleton so the test does not see counters from earlier
  // engine-test cases.
  clingfy::capture::RecordingEngine::Instance().ForceResetForTesting();

  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "getCaptureDiagnostics");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  const auto backend = map->find(flutter::EncodableValue("backend"));
  ASSERT_NE(backend, map->end());
  const auto* backend_str = std::get_if<std::string>(&backend->second);
  ASSERT_NE(backend_str, nullptr);
  EXPECT_EQ(*backend_str, "windows_mf");

  // The numeric counter keys are always present, even with no
  // recording in flight — Dart's diagnostics UI prefers a stable shape
  // over conditional fields.
  for (const auto& key : {
           "frameWidth", "frameHeight", "framesReceived",
           "framesDropped", "videoSamplesWritten",
           "audioSamplesWritten", "micPackets", "loopbackPackets",
       }) {
    const auto it = map->find(flutter::EncodableValue(key));
    ASSERT_NE(it, map->end()) << "Missing key '" << key << "'.";
  }
  EXPECT_NE(map->find(flutter::EncodableValue("micActive")), map->end());
  EXPECT_NE(map->find(flutter::EncodableValue("loopbackActive")), map->end());
  EXPECT_NE(map->find(flutter::EncodableValue("outputPath")), map->end());
}

// === Boolean false getters. ================================================

TEST(StubShapesTest, BoolGettersReturnFalse) {
  // The permissions wiring (`requestScreenRecordingPermission`,
  // `requestMicrophonePermission`, `requestCameraPermission`,
  // `isAccessibilityTrusted`) used to land here as Phase-1 false-stubs.
  // The permissions PR moved them onto the real probe — see
  // `PermissionRoutingTest.*` below.
  // checkForUpdates left this list in Phase 10.6 — it is the real D2
  // update check now (UpdaterRouterTest covers its behavior).
  MethodRouter router;
  const std::vector<std::string> kFalseGetters = {
      "getExcludeRecorderApp",
      // Mirrors the macOS default: mic echo cancellation is opt-in.
      "getMicEchoCancellationEnabled",
      "saveManualZoomSegments",
  };

  for (const auto& method : kFalseGetters) {
    const RecordedReply reply = Dispatch(router, method);
    ASSERT_TRUE(reply.success_called)
        << "Method '" << method << "' did not succeed.";
    const auto* value = std::get_if<bool>(&reply.success_value);
    ASSERT_NE(value, nullptr)
        << "Method '" << method << "' did not return a Bool.";
    EXPECT_FALSE(*value) << "Method '" << method << "' should return false.";
  }
}

// === Boolean true getters. =================================================
//
// `getExcludeMicFromSystemAudio` returns true to match the macOS default --
// the user does not want to hear their own mic in the system-audio mix.

TEST(StubShapesTest, GetExcludeMicFromSystemAudioReturnsTrue) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "getExcludeMicFromSystemAudio");
  ASSERT_TRUE(reply.success_called);
  const auto* value = std::get_if<bool>(&reply.success_value);
  ASSERT_NE(value, nullptr);
  EXPECT_TRUE(*value)
      << "Default should mirror macOS: exclude mic from system audio mix.";
}

// === Null getters. =========================================================

TEST(StubShapesTest, NullGettersReturnNull) {
  MethodRouter router;
  // Phase 10.1: getTodayLogFilePath is real now (path or
  // LOG_FILE_NOT_FOUND/UNAVAILABLE) — pinned in
  // storage_router_reveal_test.cpp.
  const std::vector<std::string> kNullGetters = {
      "previewGetSourceDimensions",
      "pickImage",
  };

  for (const auto& method : kNullGetters) {
    const RecordedReply reply = Dispatch(router, method);
    EXPECT_TRUE(reply.success_called)
        << "Method '" << method << "' did not succeed.";
    EXPECT_TRUE(reply.success_value.IsNull())
        << "Method '" << method << "' should return null.";
  }
}

// getSaveFolder / resetSaveFolder return the default save folder path so
// the settings UI and export dialog have a real directory to show and to
// hand back as directoryOverride. (Before the Slice 2 follow-up they were
// null stubs, which left every default export failing with kNoDestination.)
// chooseSaveFolder is intentionally NOT exercised here: it opens a modal
// IFileOpenDialog, which has no place in a headless test.
TEST(StubShapesTest, SaveFolderGettersReturnDefaultPath) {
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER",
                            L"C:\\Tmp\\clingfy_stub_save_folder");
  MethodRouter router;
  for (const char* method : {"getSaveFolder", "resetSaveFolder"}) {
    const RecordedReply reply = Dispatch(router, method);
    EXPECT_TRUE(reply.success_called) << method << " did not succeed.";
    const auto* path = std::get_if<std::string>(&reply.success_value);
    ASSERT_NE(path, nullptr) << method << " should return a string path.";
    EXPECT_EQ(*path, "C:\\Tmp\\clingfy_stub_save_folder") << method;
  }
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER", nullptr);
}

// === Specific shaped maps. =================================================

TEST(StubShapesTest, GetRecordingCapabilitiesReportsPauseResumeOnWindows) {
  // Phase 4 flipped canPauseResume from false to true and tagged the
  // strategy as windows_mf_pause. Dart's `RecordingPauseResumeCapabilities.
  // fromMap` reads all three keys verbatim.
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "getRecordingCapabilities");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  const auto can_pause =
      map->find(flutter::EncodableValue("canPauseResume"));
  ASSERT_NE(can_pause, map->end());
  const auto* can_pause_bool = std::get_if<bool>(&can_pause->second);
  ASSERT_NE(can_pause_bool, nullptr);
  EXPECT_TRUE(*can_pause_bool)
      << "Phase 4 wires pause/resume on the engine — the bridge must "
         "tell Dart's UI the feature is available.";

  const auto backend = map->find(flutter::EncodableValue("backend"));
  ASSERT_NE(backend, map->end());
  const auto* backend_str = std::get_if<std::string>(&backend->second);
  ASSERT_NE(backend_str, nullptr);
  EXPECT_EQ(*backend_str, "windows_mf");

  const auto strategy = map->find(flutter::EncodableValue("strategy"));
  ASSERT_NE(strategy, map->end());
  const auto* strategy_str = std::get_if<std::string>(&strategy->second);
  ASSERT_NE(strategy_str, nullptr);
  EXPECT_EQ(*strategy_str, "windows_mf_pause");
}

TEST(StubShapesTest, PreviewGetZoomCapabilitiesReportsAllFalse) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "previewGetZoomCapabilities");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  for (const char* key : {"cursorSamples", "fixedTargetPreview",
                          "fixedTargetExport"}) {
    const auto it = map->find(flutter::EncodableValue(key));
    ASSERT_NE(it, map->end()) << "Missing key '" << key << "'.";
    const auto* b = std::get_if<bool>(&it->second);
    ASSERT_NE(b, nullptr) << "Key '" << key << "' is not a bool.";
    EXPECT_FALSE(*b)
        << "Key '" << key
        << "' should be false so Dart hides the smart fixed-target UX.";
  }
}

TEST(StubShapesTest, PreviewGetCursorSamplesReturnsEmptyPayload) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "previewGetCursorSamples");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  const auto samples = map->find(flutter::EncodableValue("samples"));
  ASSERT_NE(samples, map->end());
  const auto* samples_list =
      std::get_if<flutter::EncodableList>(&samples->second);
  ASSERT_NE(samples_list, nullptr);
  EXPECT_TRUE(samples_list->empty());

  EXPECT_NE(map->find(flutter::EncodableValue("width")), map->end());
  EXPECT_NE(map->find(flutter::EncodableValue("height")), map->end());
}

TEST(StubShapesTest, GetRecordingSceneInfoBundleMissingReturnsSceneInputMissing) {
  // Step 5.2: the Phase 1 stub that echoed projectPath into screenPath
  // is gone. The production handler now reads the manifest via
  // RecordingProjectReader; a bogus path fails with SCENE_INPUT_MISSING
  // (matching the macOS PreviewSceneResolver). Fuller per-shape coverage
  // (happy paths, BAD_ARGS, camera assets) lives in
  // preview_router_test.cpp.
  MethodRouter router;
  flutter::EncodableMap args{
      {flutter::EncodableValue("projectPath"),
       flutter::EncodableValue(std::string("/some/project.clingfy"))},
  };
  const RecordedReply reply =
      DispatchWithArgs(router, "getRecordingSceneInfo", std::move(args));

  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "SCENE_INPUT_MISSING");
}

TEST(StubShapesTest, ClearCachedRecordingsReturnsZeroDeleted) {
  // Phase 10.3: the handler is REAL (deletes project dirs under the
  // recordings root). Sandbox it to an empty temp dir — zero projects →
  // zero deletions; richer behavior is pinned in storage_truth_test.cpp.
  const auto sandbox = std::filesystem::temp_directory_path() /
                       L"clingfy_stub_clear_sandbox";
  std::filesystem::create_directories(sandbox);
  ::SetEnvironmentVariableW(L"CLINGFY_RECORDINGS_ROOT",
                            sandbox.wstring().c_str());
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "clearCachedRecordings");
  ::SetEnvironmentVariableW(L"CLINGFY_RECORDINGS_ROOT", nullptr);
  std::error_code cleanup_ec;
  std::filesystem::remove_all(sandbox, cleanup_ec);
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  const auto it = map->find(flutter::EncodableValue("deletedCount"));
  ASSERT_NE(it, map->end());
  const auto* count = std::get_if<int32_t>(&it->second);
  ASSERT_NE(count, nullptr);
  EXPECT_EQ(*count, 0);
}

TEST(StubShapesTest, GetStorageSnapshotReturnsAllRequiredKeys) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "getStorageSnapshot");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  // Mirror the keys read by StorageSnapshot.fromMap on the Dart side
  // (lib/core/models/storage_snapshot.dart). All ten must be present.
  for (const char* key : {
           "systemTotalBytes",
           "systemAvailableBytes",
           "recordingsBytes",
           "tempBytes",
           "logsBytes",
           "recordingsPath",
           "tempPath",
           "logsPath",
           "warningThresholdBytes",
           "criticalThresholdBytes",
       }) {
    EXPECT_NE(map->find(flutter::EncodableValue(key)), map->end())
        << "Missing key '" << key << "' in storage snapshot stub.";
  }
}

// === Pause / resume now go through the engine ==============================
//
// Phase 4 swapped the Phase-1 no-op pause/resume stubs for real engine
// calls. With no active recording, the engine returns kNotRecording —
// the router translates that into a structured error reply (not a
// silent success) so Dart's defensive double-tap surfaces a useful
// code instead of pretending nothing happened.

TEST(StubShapesTest, PauseResumeReturnNotRecordingWhenIdle) {
  clingfy::capture::RecordingEngine::Instance().ForceResetForTesting();
  MethodRouter router;
  for (const auto& method : {"pauseRecording", "resumeRecording",
                             "togglePauseRecording"}) {
    const RecordedReply reply = Dispatch(router, method);
    EXPECT_TRUE(reply.error_called)
        << "Method '" << method
        << "' should surface a structured error when no session is active.";
    EXPECT_EQ(reply.error_code, error::kNotRecording)
        << "Method '" << method
        << "' should use the NOT_RECORDING code so Dart can localize the "
           "matching toast.";
  }
}

// === Phase 3A — engine-backed start / stop wiring. =========================
//
// These tests pin the router-level translation between Dart-shaped arguments
// and the `RecordingEngine` calls. The engine itself has its own dedicated
// test file (`recording_engine_test.cpp`); these only confirm that the
// router parses arguments correctly and that engine errors propagate as
// structured `MethodResult::Error` calls instead of swallowed successes.

TEST(StubShapesTest, StartRecordingWithoutArgsReturnsBadArgs) {
  // Reset the engine state because the router uses the process-wide
  // singleton — previous tests may have left it in a non-idle state.
  clingfy::capture::RecordingEngine::Instance().ForceResetForTesting();

  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "startRecording");
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kBadArgs);
  EXPECT_EQ(clingfy::capture::RecordingEngine::Instance().state(),
            clingfy::capture::RecordingState::kIdle)
      << "A bad-args rejection must NOT mutate engine state.";
}

TEST(StubShapesTest, StartRecordingWithSessionIdSucceeds) {
  clingfy::capture::RecordingEngine::Instance().ForceResetForTesting();

  MethodRouter router;
  flutter::EncodableMap args{
      {flutter::EncodableValue("sessionId"),
       flutter::EncodableValue(std::string("router-test"))},
      {flutter::EncodableValue("frameRate"),
       flutter::EncodableValue(static_cast<std::int32_t>(60))},
      {flutter::EncodableValue("systemAudioEnabled"),
       flutter::EncodableValue(true)},
  };

  const RecordedReply start_reply =
      DispatchWithArgs(router, "startRecording", std::move(args));
  ASSERT_TRUE(start_reply.success_called) << start_reply.error_message;
  EXPECT_FALSE(start_reply.error_called);
  EXPECT_TRUE(clingfy::capture::RecordingEngine::Instance().IsRecording());

  // Stop with a matching session id closes the lifecycle cleanly.
  flutter::EncodableMap stop_args{
      {flutter::EncodableValue("sessionId"),
       flutter::EncodableValue(std::string("router-test"))},
  };
  const RecordedReply stop_reply =
      DispatchWithArgs(router, "stopRecording", std::move(stop_args));
  ASSERT_TRUE(stop_reply.success_called) << stop_reply.error_message;
  EXPECT_EQ(clingfy::capture::RecordingEngine::Instance().state(),
            clingfy::capture::RecordingState::kIdle);
}

TEST(StubShapesTest, GetRecordingCapabilitiesReportsWindowsMfBackend) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "getRecordingCapabilities");
  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);
  const auto backend = map->find(flutter::EncodableValue("backend"));
  ASSERT_NE(backend, map->end());
  const auto* backend_str = std::get_if<std::string>(&backend->second);
  ASSERT_NE(backend_str, nullptr);
  EXPECT_EQ(*backend_str, "windows_mf")
      << "Phase 3A flips the placeholder backend identifier to the real "
         "Windows engine name so diagnostics surface it.";
}

}  // namespace
}  // namespace clingfy::bridge
