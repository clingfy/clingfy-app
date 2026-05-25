#include "Bridge/Routers/permissions_router.h"

#include <flutter/encodable_value.h>

#include <string>

#include "Bridge/result_helpers.h"
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

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["getPermissionStatus"] = &HandleGetPermissionStatus;
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
