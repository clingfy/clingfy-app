#include "Bridge/method_router.h"

#include <gtest/gtest.h>

#include <flutter/encodable_value.h>

#include <string>
#include <vector>

#include "Bridge/native_error_codes.h"
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

// === Setters return success with no value. =================================

TEST(StubShapesTest, NoopSettersReturnSuccessWithNullValue) {
  MethodRouter router;
  // Sample of methods from each domain that should be no-op success.
  const std::vector<std::string> kSetters = {
      "setRecordingQuality",
      "setFileNameTemplate",
      "setExcludeRecorderApp",
      "setExcludeMicFromSystemAudio",
      "setCaptureFrameRate",
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
      "setRecordingIndicatorPinned",
      "setPreRecordingBarEnabled",
      "setPreRecordingBarVisible",
      "showPreRecordingBar",
      "togglePreRecordingBar",
      "setPreRecordingBarState",
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
      "cancelExport",
      "openAccessibilitySettings",
      "openScreenRecordingSettings",
      "openSystemSettings",
      "relaunchApp",
      "openSaveFolder",
      "revealTodayLogFile",
      "revealLogsFolder",
      "revealRecordingsFolder",
      "revealTempFolder",
      "revealFile",
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

// === Action methods that must return WINDOWS_NOT_IMPLEMENTED. ==============

TEST(StubShapesTest, RecordingAndExportActionsReturnNotImplemented) {
  MethodRouter router;
  const std::vector<std::string> kBlocked = {
      "startRecording",
      "stopRecording",
      "exportVideo",
      "processVideo",
  };

  for (const auto& method : kBlocked) {
    const RecordedReply reply = Dispatch(router, method);
    EXPECT_TRUE(reply.error_called)
        << "Method '" << method
        << "' should return a structured error in Phase 1.";
    EXPECT_EQ(reply.error_code, error::kWindowsNotImplemented)
        << "Method '" << method
        << "' should use the WINDOWS_NOT_IMPLEMENTED error code.";
  }
}

// === Empty-list getters. ===================================================

TEST(StubShapesTest, ListGettersReturnEmptyList) {
  MethodRouter router;
  const std::vector<std::string> kListGetters = {
      "getDisplays",      "getAppWindows",        "getAudioSources",
      "getVideoSources",  "getZoomSegments",      "getManualZoomSegments",
  };

  for (const auto& method : kListGetters) {
    const RecordedReply reply = Dispatch(router, method);
    ASSERT_TRUE(reply.success_called)
        << "Method '" << method << "' did not succeed.";
    const auto* list = std::get_if<flutter::EncodableList>(&reply.success_value);
    ASSERT_NE(list, nullptr)
        << "Method '" << method << "' did not return a List.";
    EXPECT_TRUE(list->empty())
        << "Method '" << method
        << "' should return an empty list until Phase 2 wires up the real "
           "discovery.";
  }
}

// === Empty-map getters. ====================================================

TEST(StubShapesTest, MapGettersReturnEmptyMap) {
  MethodRouter router;
  const std::vector<std::string> kMapGetters = {
      "getPermissionStatus",
      "getCaptureDiagnostics",
  };

  for (const auto& method : kMapGetters) {
    const RecordedReply reply = Dispatch(router, method);
    ASSERT_TRUE(reply.success_called)
        << "Method '" << method << "' did not succeed.";
    const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
    ASSERT_NE(map, nullptr)
        << "Method '" << method << "' did not return a Map.";
    EXPECT_TRUE(map->empty())
        << "Method '" << method << "' should return an empty map.";
  }
}

// === Boolean false getters. ================================================

TEST(StubShapesTest, BoolGettersReturnFalse) {
  MethodRouter router;
  const std::vector<std::string> kFalseGetters = {
      "getExcludeRecorderApp",
      "requestScreenRecordingPermission",
      "requestMicrophonePermission",
      "requestCameraPermission",
      "isAccessibilityTrusted",
      "checkForUpdates",
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
  const std::vector<std::string> kNullGetters = {
      "getSaveFolder",
      "chooseSaveFolder",
      "resetSaveFolder",
      "getTodayLogFilePath",
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

// === Specific shaped maps. =================================================

TEST(StubShapesTest, GetRecordingCapabilitiesReportsUnsupported) {
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
  EXPECT_FALSE(*can_pause_bool);

  const auto backend = map->find(flutter::EncodableValue("backend"));
  ASSERT_NE(backend, map->end());
  EXPECT_NE(std::get_if<std::string>(&backend->second), nullptr);

  const auto strategy = map->find(flutter::EncodableValue("strategy"));
  ASSERT_NE(strategy, map->end());
  EXPECT_NE(std::get_if<std::string>(&strategy->second), nullptr);
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

TEST(StubShapesTest, GetRecordingSceneInfoEchoesProjectPath) {
  MethodRouter router;
  flutter::EncodableMap args{
      {flutter::EncodableValue("projectPath"),
       flutter::EncodableValue(std::string("/some/project.clingfy"))},
  };
  const RecordedReply reply =
      DispatchWithArgs(router, "getRecordingSceneInfo", std::move(args));

  ASSERT_TRUE(reply.success_called);
  const auto* map = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(map, nullptr);

  const auto project = map->find(flutter::EncodableValue("projectPath"));
  ASSERT_NE(project, map->end());
  const auto* project_str = std::get_if<std::string>(&project->second);
  ASSERT_NE(project_str, nullptr);
  EXPECT_EQ(*project_str, "/some/project.clingfy");

  const auto screen = map->find(flutter::EncodableValue("screenPath"));
  ASSERT_NE(screen, map->end());
  const auto* screen_str = std::get_if<std::string>(&screen->second);
  ASSERT_NE(screen_str, nullptr);
  EXPECT_EQ(*screen_str, "/some/project.clingfy")
      << "Phase 1 stub mirrors projectPath into screenPath -- matches Dart's "
         "own fallback when native returns null.";
}

TEST(StubShapesTest, ClearCachedRecordingsReturnsZeroDeleted) {
  MethodRouter router;
  const RecordedReply reply = Dispatch(router, "clearCachedRecordings");
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

// === Pause / resume should not surface a spurious error. ===================
//
// There is no live recording on Phase 1, but the Flutter side may issue
// these defensively. We return success so the UI does not throw.

TEST(StubShapesTest, PauseResumeAreNoopSuccess) {
  MethodRouter router;
  for (const auto& method : {"pauseRecording", "resumeRecording",
                             "togglePauseRecording"}) {
    const RecordedReply reply = Dispatch(router, method);
    EXPECT_TRUE(reply.success_called)
        << "Method '" << method << "' should succeed as no-op.";
    EXPECT_FALSE(reply.error_called)
        << "Method '" << method << "' should not surface an error.";
  }
}

}  // namespace
}  // namespace clingfy::bridge
