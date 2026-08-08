#include "Bridge/method_router.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <string>
#include <unordered_set>
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
      "getMicEchoCancellationEnabled",
      "setMicEchoCancellationEnabled",
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
      // getCameraPreviewTextureId was retired with the in-app camera preview
      // widget (the floating bubble is the only live preview); the native
      // handler + LiveCameraTexture feed were removed in the follow-up
      // cleanup.
      "setCameraPreviewMode",

      // Recording indicator + pre-recording bar.
      "setRecordingIndicatorPinned",
      "setPreRecordingBarEnabled",
      "setPreRecordingBarVisible",
      "showPreRecordingBar",
      "togglePreRecordingBar",
      "setPreRecordingBarState",

      // Diagnostics.
      "setNativeLogLevel",
      "flushPendingNativeLogs",

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
      "previewSetVoiceCleanup",
      "previewSetColorGrade",
      "previewSetCanvas",
      "canvasPresetThumbnail",
      "previewSetClips",
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

      // Phase 10.4 crash salvage + crash-pipeline verification.
      "getStartupRecoveryReport",
      "debugForceNativeCrash",

      // Permissions + system shortcuts.
      "getPermissionStatus",
      "getWindowsPermissionDetails",
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

      // Captions (macOS-only feature; Windows answers "unavailable" with a
      // reason rather than letting the Flutter side see a missing handler).
      "captionsCapability",
      "generateCaptions",
      "cancelCaptions",

      // Updater (Phase 10.6 — updater_router.cpp).
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

TEST(BridgeContractCoverageTest, EveryRegisteredHandlerIsOnTheDartContract) {
  MethodRouter router;
  const auto& contract = BridgeContractMethods();
  const std::unordered_set<std::string> listed(contract.begin(),
                                               contract.end());

  std::vector<std::string> unlisted;
  for (const auto& method : router.RegisteredMethodNames()) {
    if (listed.find(method) == listed.end()) {
      unlisted.push_back(method);
    }
  }
  std::sort(unlisted.begin(), unlisted.end());

  EXPECT_TRUE(unlisted.empty())
      << "The following methods have a registered handler in a "
         "windows/runner/Bridge/Routers/*.cpp file but are MISSING from "
         "BridgeContractMethods() above. A registered-but-unlisted method "
         "drifts silently (the other test only proves the listed direction). "
         "Add each to the contract list here so the Dart<->Windows bridge "
         "stays fully accounted for:\n  - "
      << [&unlisted] {
           std::string joined;
           for (size_t i = 0; i < unlisted.size(); ++i) {
             if (i != 0) joined += "\n  - ";
             joined += unlisted[i];
           }
           return joined;
         }();
}

}  // namespace
}  // namespace clingfy::bridge
