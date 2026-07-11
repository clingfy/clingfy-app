#include "Bridge/Routers/indicator_router.h"

#include <string>
#include <variant>

#include "Bridge/native_log_publisher.h"
#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::indicator {

namespace {

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

// Runtime log-verbosity push from the Settings "verbose logging" toggle. Dart
// (workspace_settings_controller) sends the resolved level name; route it to the
// native log threshold so native DEBUG lines start/stop crossing the channel in
// step with the toggle (mirrors macOS `NativeLogger.setMinLevel`). Unknown
// values are ignored engine-side. Always replies null (the void Dart contract).
void HandleSetNativeLogLevel(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    const auto it = args->find(flutter::EncodableValue("level"));
    if (it != args->end()) {
      if (const auto* level = std::get_if<std::string>(&it->second)) {
        NativeLogPublisher::Instance().SetMinLevel(*level);
      }
    }
  }
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

  // Runtime log-verbosity push from the Settings "verbose logging" toggle —
  // pushes the level into the native log threshold (NativeLogPublisher), so
  // native DEBUG tracing follows the toggle, matching macOS.
  table["setNativeLogLevel"] = &HandleSetNativeLogLevel;
}

}  // namespace clingfy::bridge::routers::indicator
