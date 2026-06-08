#include "Bridge/method_router.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace clingfy::bridge {
namespace {

// Authoritative list of every method on the Flutter -> Native bridge.
//
// Source of truth on the Dart side is `lib/core/bridges/native_method_channel.dart`
// + the explicit `invokeMethod(...)` calls in `lib/core/bridges/native_bridge.dart`
// and friends. Source on the macOS side is the dispatch switch in
// `macos/Runner/MainFlutterWindow.swift` plus `PermissionsMethodRouter.swift`.
//
// This list intentionally duplicates that contract so a Phase 1-style
// drift -- a typo in a router file, a forgotten registration, an accidental
// removal -- shows up as a failing test rather than as a silent
// `WINDOWS_NOT_IMPLEMENTED` at runtime.
//
// Adding a method to the bridge means: register it in the right
// `Routers/*.cpp` file AND add it here. Removing one means the same in
// reverse.
const std::vector<std::string>& BridgeContractMethods() {
  static const std::vector<std::string> kMethods = {
      // Recording lifecycle + settings.
      "startRecording",
      "stopRecording",
      "pauseRecording",
      "resumeRecording",
      "togglePauseRecording",
      "getRecordingCapabilities",
      "setRecordingQuality",
      "setFileNameTemplate",
      "getExcludeRecorderApp",
      "setExcludeRecorderApp",
      "getExcludeMicFromSystemAudio",
      "setExcludeMicFromSystemAudio",
      "setCaptureFrameRate",
      "getCaptureDiagnostics",

      // Display / window / audio / video discovery + selection.
      "getDisplays",
      "getAppWindows",
      "getAudioSources",
      "getVideoSources",
      "setDisplay",
      "setAppWindowTarget",
      "setDisplayTargetMode",
      "setAudioSource",
      "setVideoSource",
      "updateAudioPreview",
      "setAudioMix",
      "setAudioGainDb",
      "pickAreaRecordingRegion",
      "revealAreaRecordingRegion",
      "clearAreaRecordingSelection",

      // Camera overlay + chroma + cursor highlight.
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
      "getCameraPreviewTextureId",

      // Recording indicator + pre-recording bar.
      "setRecordingIndicatorPinned",
      "setPreRecordingBarEnabled",
      "setPreRecordingBarVisible",
      "showPreRecordingBar",
      "togglePreRecordingBar",
      "setPreRecordingBarState",

      // Preview / player / zoom.
      "previewOpen",
      "previewClose",
      "previewPlay",
      "previewPause",
      "previewSeekTo",
      "previewPeekTo",
      "playerPlay",
      "playerPause",
      "playerSeekTo",
      "inlinePreviewStop",
      "previewSetCameraPlacement",
      "previewSetZoomSegments",
      "previewSetAudioMix",
      "previewSetAudioGainDb",
      "previewGetZoomCapabilities",
      "previewGetCursorSamples",
      "previewGetSourceDimensions",

      // Export + project queries.
      "exportVideo",
      "processVideo",
      "cancelExport",
      "getRecordingSceneInfo",
      "getZoomSegments",
      "getManualZoomSegments",
      "saveManualZoomSegments",

      // Permissions + system shortcuts.
      "getPermissionStatus",
      "requestScreenRecordingPermission",
      "requestMicrophonePermission",
      "requestCameraPermission",
      "isAccessibilityTrusted",
      "openAccessibilitySettings",
      "openScreenRecordingSettings",
      "openSystemSettings",
      "relaunchApp",

      // Storage + reveal helpers.
      "getSaveFolder",
      "chooseSaveFolder",
      "resetSaveFolder",
      "openSaveFolder",
      "getTodayLogFilePath",
      "revealTodayLogFile",
      "revealLogsFolder",
      "revealRecordingsFolder",
      "revealTempFolder",
      "revealFile",
      "clearCachedRecordings",
      "getStorageSnapshot",

      // Misc.
      "pickImage",
      "cacheLocalizedStrings",
      "checkForUpdates",

      // (Stage 2A POC aliases pocStage2aStart / pocStage2aStop were
      // retired in Step 5.3 along with the debug screen — production
      // previewOpen / previewClose drive the same PreviewEngine now.)
  };
  return kMethods;
}

TEST(BridgeContractCoverageTest, EveryDartContractMethodHasARegisteredHandler) {
  MethodRouter router;

  std::vector<std::string> missing;
  for (const auto& method : BridgeContractMethods()) {
    if (!router.HasHandler(method)) {
      missing.push_back(method);
    }
  }

  EXPECT_TRUE(missing.empty())
      << "The following methods are on the Dart bridge contract but have no "
         "registered handler in any windows/runner/Bridge/Routers/*.cpp file. "
         "Add the missing registration (and a stub handler) so the Flutter UI "
         "does not see a WINDOWS_NOT_IMPLEMENTED error at runtime:\n  - "
      << [&missing] {
           std::string joined;
           for (size_t i = 0; i < missing.size(); ++i) {
             if (i != 0) joined += "\n  - ";
             joined += missing[i];
           }
           return joined;
         }();
}

}  // namespace
}  // namespace clingfy::bridge
