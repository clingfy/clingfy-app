#include "Bridge/Routers/indicator_router.h"

#include <string>
#include <variant>

#include "Bridge/native_log_publisher.h"
#include "Bridge/result_helpers.h"
#include "Capture/Indicator/recording_indicator_controller.h"

namespace clingfy::bridge::routers::indicator {

namespace {

// Slice 3: pin / unpin the on-screen recording indicator. Dart's
// SettingsController pushes the persisted `indicatorPinned` bool on startup and
// on toggle (mirrors macOS setRecordingIndicatorPinned). Parse the `pinned` key
// like HandleSetNativeLogLevel and forward to the overlay controller, which
// snaps the pill to the corner (pinned) or restores drag (unpinned). The void
// Dart contract: always reply null.
void HandleSetRecordingIndicatorPinned(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    const auto it = args->find(flutter::EncodableValue("pinned"));
    if (it != args->end()) {
      if (const auto* pinned = std::get_if<bool>(&it->second)) {
        clingfy::capture::RecordingIndicatorController::Instance().SetPinned(
            *pinned);
      }
    }
  }
  reply::Null(*result);
}

// Dart's NativeBridge calls this right after installing its 'log' handler:
// drain the lines native buffered during startup (before the channel/handler
// existed) into the unified Dart log pipeline. Mirrors macOS
// `NativeLogger.flushPending`. Always replies null (fire-and-forget in Dart).
void HandleFlushPendingNativeLogs(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  NativeLogPublisher::Instance().FlushPending();
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
  table["setRecordingIndicatorPinned"] = &HandleSetRecordingIndicatorPinned;

  // The pre-recording bar methods (setPreRecordingBar*/show/toggle) moved to
  // `routers::pre_recording_bar` (Slice 4) — they now drive a real Win32
  // overlay instead of a no-op.

  // Runtime log-verbosity push from the Settings "verbose logging" toggle —
  // pushes the level into the native log threshold (NativeLogPublisher), so
  // native DEBUG tracing follows the toggle, matching macOS.
  table["setNativeLogLevel"] = &HandleSetNativeLogLevel;

  // Dart-ready handshake that drains the pre-channel native log buffer.
  table["flushPendingNativeLogs"] = &HandleFlushPendingNativeLogs;
}

}  // namespace clingfy::bridge::routers::indicator
