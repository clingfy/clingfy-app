#include "Bridge/Routers/permissions_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::permissions {

namespace {

void HandleEmptyMap(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::EmptyMap(*result);
}

void HandleFalse(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Bool(*result, false);
}

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["getPermissionStatus"] = &HandleEmptyMap;
  table["requestScreenRecordingPermission"] = &HandleFalse;
  table["requestMicrophonePermission"] = &HandleFalse;
  table["requestCameraPermission"] = &HandleFalse;
  table["isAccessibilityTrusted"] = &HandleFalse;

  table["openAccessibilitySettings"] = &HandleNoopSetter;
  table["openScreenRecordingSettings"] = &HandleNoopSetter;
  table["openSystemSettings"] = &HandleNoopSetter;
  table["relaunchApp"] = &HandleNoopSetter;
}

}  // namespace clingfy::bridge::routers::permissions
