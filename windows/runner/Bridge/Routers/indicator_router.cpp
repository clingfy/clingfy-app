#include "Bridge/Routers/indicator_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::indicator {

namespace {

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["setRecordingIndicatorPinned"] = &HandleNoopSetter;

  // macOS routes both `setPreRecordingBarEnabled` and
  // `setPreRecordingBarVisible` through the same handler -- mirror that here
  // so we stay aligned with the Dart contract.
  table["setPreRecordingBarEnabled"] = &HandleNoopSetter;
  table["setPreRecordingBarVisible"] = &HandleNoopSetter;
  table["showPreRecordingBar"] = &HandleNoopSetter;
  table["togglePreRecordingBar"] = &HandleNoopSetter;
  table["setPreRecordingBarState"] = &HandleNoopSetter;

  // Runtime log-verbosity push from the Settings "verbose logging" toggle.
  // No-op on Windows for now (Windows logging honors the CLINGFY_LOG_LEVEL env
  // var at startup; a runtime level set is a future task).
  table["setNativeLogLevel"] = &HandleNoopSetter;
}

}  // namespace clingfy::bridge::routers::indicator
