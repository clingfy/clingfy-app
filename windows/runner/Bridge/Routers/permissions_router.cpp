#include "Bridge/Routers/permissions_router.h"

#include <flutter/encodable_value.h>

#include <algorithm>
#include <string>
#include <vector>

#include "Bridge/Devices/audio_source_enumerator.h"
#include "Bridge/Devices/video_source_enumerator.h"
#include "Bridge/result_helpers.h"
#include "Capture/windows_selection_state.h"
#include "Permissions/camera_readiness.h"
#include "Permissions/permission_probe.h"

namespace clingfy::bridge::routers::permissions {

namespace {

const flutter::EncodableMap* AsMap(
    const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableMap>(arguments);
}

std::string ReadString(const flutter::EncodableMap& map,
                       const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return {};
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return {};
}

// ---- getPermissionStatus ---------------------------------------------------
//
// Returns the flat `Map<String, bool>` shape `PermissionStatusSnapshot.
// fromStatusMap` parses (lib/core/permissions/models/
// permission_status_snapshot.dart). Screen recording + accessibility
// are always `true` on Windows; mic and camera reflect the live
// `AppCapabilityAccess` check.
void HandleGetPermissionStatus(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto snap = clingfy::permissions::ProbePermissionStatus();
  reply::Map(*result, flutter::EncodableMap{
                          {flutter::EncodableValue("screenRecording"),
                           flutter::EncodableValue(snap.screen_recording)},
                          {flutter::EncodableValue("microphone"),
                           flutter::EncodableValue(snap.microphone)},
                          {flutter::EncodableValue("camera"),
                           flutter::EncodableValue(snap.camera)},
                          {flutter::EncodableValue("accessibility"),
                           flutter::EncodableValue(snap.accessibility)},
                      });
}

// Phase 1 returned `false` for every request. Windows desktop apps
// can't trigger the system prompt directly, so we instead probe the
// current state — when denied we deep-link to the Settings page so
// the user can flip the toggle — and return the live boolean. This
// matches Dart's `Future<bool>` contract: the result reflects "is the
// permission usable right now".
bool RequestAndOpenSettingsIfDenied(bool current, const std::string& pane) {
  if (!current) {
    clingfy::permissions::LaunchSettingsUri(
        clingfy::permissions::ResolveSettingsUri(pane));
  }
  return current;
}

void HandleRequestScreenRecording(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Windows has no screen-recording gate — always granted.
  reply::Bool(*result, true);
}

void HandleRequestMicrophone(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const bool current =
      clingfy::permissions::ProbePermissionStatus().microphone;
  reply::Bool(*result, RequestAndOpenSettingsIfDenied(current, "microphone"));
}

void HandleRequestCamera(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const bool current = clingfy::permissions::ProbePermissionStatus().camera;
  reply::Bool(*result, RequestAndOpenSettingsIfDenied(current, "camera"));
}

void HandleIsAccessibilityTrusted(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // No analogue on Windows — cursor + input capture work without an
  // AX-style trust gate.
  reply::Bool(*result, true);
}

// ---- Settings deep-link handlers ------------------------------------------

void HandleOpenAccessibilitySettings(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  clingfy::permissions::LaunchSettingsUri(
      clingfy::permissions::ResolveSettingsUri("accessibility"));
  reply::Null(*result);
}

void HandleOpenScreenRecordingSettings(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  clingfy::permissions::LaunchSettingsUri(
      clingfy::permissions::ResolveSettingsUri("screenRecording"));
  reply::Null(*result);
}

// Dart's `openSystemSettings(pane)` is the generic deep-link entry. Pane
// is one of the names `permissions_controller.dart` quotes —
// "microphone" / "camera" so far; future panes can be added by
// extending `ResolveSettingsUri` without touching this handler.
void HandleOpenSystemSettings(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string pane;
  if (const auto* args = AsMap(call.arguments())) {
    pane = ReadString(*args, "pane");
    if (pane.empty()) {
      pane = ReadString(*args, "name");
    }
  }
  if (!pane.empty()) {
    clingfy::permissions::LaunchSettingsUri(
        clingfy::permissions::ResolveSettingsUri(pane));
  }
  reply::Null(*result);
}

void HandleRelaunchApp(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Phase 10 (installer + updater) will hook the proper relaunch
  // semantics. For permissions UX, the user fixes the toggle and
  // simply continues — no relaunch is required on Windows.
  reply::Null(*result);
}

// ---- getWindowsPermissionDetails (Phase 10.2) ------------------------------
//
// The rich permission/device picture the Windows-specific UI renders.
// `getPermissionStatus` stays the flat cross-platform bool map; this method
// is Windows-only (Dart guards it with a MissingPluginException fallback, so
// macOS/legacy-native simply yields null and the UI falls back to booleans).
// Wire names come from CameraReadinessCodeName / CameraPermissionName — keep
// in sync with lib/core/permissions/models/windows_permission_details.dart.
//
// Reply shape:
//   { camera:        { code, reason, deviceSelected, devicesAvailable },
//     microphone:    { access, deviceSelected, selectedDeviceMissing },
//     screenRecording: { required: false } }
void HandleGetWindowsPermissionDetails(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  namespace perms = clingfy::permissions;
  namespace devices = clingfy::bridge::devices;
  auto& selection = clingfy::capture::WindowsSelectionState::Instance();

  // Camera: privacy probe + live enumeration → the Phase 9.1 resolver.
  // Two platform-thread-stall guards (this handler runs on every panel
  // open / onboarding boot / app resume): the enumeration is SKIPPED when
  // the privacy gate already fails (the resolver returns before consulting
  // ids anyway), and otherwise runs with a single attempt — the 3-attempt
  // retry budget exists for capture cold-starts, and on a camera-less
  // machine it would sleep ~400ms per refresh.
  const perms::CameraPermission cam_permission = perms::ProbeCameraPermission();
  const std::optional<std::string> cam_selected = selection.VideoSourceId();
  std::vector<std::string> cam_ids;
  const bool cam_privacy_open =
      cam_permission == perms::CameraPermission::kGranted ||
      cam_permission == perms::CameraPermission::kUnavailableApi;
  if (cam_privacy_open) {
    for (const auto& rec : devices::EnumerateVideoInputs(/*max_attempts=*/1)) {
      cam_ids.push_back(rec.id);
    }
  }
  const perms::CameraReadinessResult cam_readiness =
      perms::ResolveCameraReadiness(cam_permission, cam_selected, cam_ids);

  // Microphone: detailed privacy bucket + does the selected endpoint still
  // exist (empty selection = system default, which is never "missing").
  const perms::CameraPermission mic_access = perms::ProbeMicrophonePermission();
  const std::optional<std::string> mic_selected = selection.MicrophoneId();
  bool mic_selected_missing = false;
  if (mic_selected.has_value() && !mic_selected->empty()) {
    const auto mics = devices::EnumerateAudioInputs();
    mic_selected_missing =
        std::none_of(mics.begin(), mics.end(), [&](const auto& rec) {
          return rec.id == *mic_selected;
        });
  }

  reply::Map(
      *result,
      flutter::EncodableMap{
          {flutter::EncodableValue("camera"),
           flutter::EncodableValue(flutter::EncodableMap{
               {flutter::EncodableValue("code"),
                flutter::EncodableValue(
                    perms::CameraReadinessCodeName(cam_readiness.code))},
               {flutter::EncodableValue("reason"),
                flutter::EncodableValue(
                    perms::CameraReadinessReason(cam_readiness.code))},
               {flutter::EncodableValue("deviceSelected"),
                flutter::EncodableValue(cam_selected.has_value())},
               {flutter::EncodableValue("devicesAvailable"),
                flutter::EncodableValue(static_cast<int>(cam_ids.size()))},
           })},
          {flutter::EncodableValue("microphone"),
           flutter::EncodableValue(flutter::EncodableMap{
               {flutter::EncodableValue("access"),
                flutter::EncodableValue(
                    perms::CameraPermissionName(mic_access))},
               {flutter::EncodableValue("deviceSelected"),
                flutter::EncodableValue(mic_selected.has_value() &&
                                        !mic_selected->empty())},
               {flutter::EncodableValue("selectedDeviceMissing"),
                flutter::EncodableValue(mic_selected_missing)},
           })},
          // Explicit truth for the UI: Windows needs no screen-capture grant.
          {flutter::EncodableValue("screenRecording"),
           flutter::EncodableValue(flutter::EncodableMap{
               {flutter::EncodableValue("required"),
                flutter::EncodableValue(false)},
           })},
      });
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["getPermissionStatus"] = &HandleGetPermissionStatus;
  table["getWindowsPermissionDetails"] = &HandleGetWindowsPermissionDetails;
  table["requestScreenRecordingPermission"] = &HandleRequestScreenRecording;
  table["requestMicrophonePermission"] = &HandleRequestMicrophone;
  table["requestCameraPermission"] = &HandleRequestCamera;
  table["isAccessibilityTrusted"] = &HandleIsAccessibilityTrusted;

  table["openAccessibilitySettings"] = &HandleOpenAccessibilitySettings;
  table["openScreenRecordingSettings"] = &HandleOpenScreenRecordingSettings;
  table["openSystemSettings"] = &HandleOpenSystemSettings;
  table["relaunchApp"] = &HandleRelaunchApp;
}

}  // namespace clingfy::bridge::routers::permissions
