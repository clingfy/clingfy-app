#ifndef RUNNER_BRIDGE_NATIVE_LOG_PUBLISHER_H_
#define RUNNER_BRIDGE_NATIVE_LOG_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <mutex>
#include <string>

// Phase 10.1: the Windows counterpart of macOS `NativeLogger.swift`.
//
// Forwards native log lines into the Dart logging pipeline with a reverse
// method-channel call `channel.invokeMethod("log", payload)`. Dart's
// NativeBridge routes that to `Log.nativeEvent`, which lands the line in the
// JSONL file logs and in Sentry (breadcrumb for every level; native-origin
// ERROR becomes a Sentry exception via the telemetry sink). This is what
// makes native failures visible in beta reports — file-only breadcrumbs
// (LogDeviceProbe / LogNative) never leave the user's machine on their own.
//
// Use it for WARN/ERROR-worthy moments (device open failures, degradations,
// orphan sweeps), not for per-frame chatter — every call crosses the
// platform-thread boundary and lands in the user's log file.
//
// Threading mirrors ExportProgressPublisher: callable from any thread; the
// InvokeMethod is marshaled to the platform thread via
// PlatformThreadDispatcher; emits are dropped silently when no channel is
// attached (startup races / teardown / tests).
namespace clingfy::bridge {

class NativeLogPublisher {
 public:
  static NativeLogPublisher& Instance();

  NativeLogPublisher(const NativeLogPublisher&) = delete;
  NativeLogPublisher& operator=(const NativeLogPublisher&) = delete;

  // Borrow the screen_recorder method channel (owned by MethodDispatcher).
  // Set at FlutterWindow startup, cleared at teardown BEFORE the channel
  // is destroyed.
  void SetChannel(flutter::MethodChannel<flutter::EncodableValue>* channel);
  void ClearChannel();

  void Info(const std::string& category, const std::string& message);
  void Warn(const std::string& category, const std::string& message);
  void Error(const std::string& category, const std::string& message);

  // Pure payload builder — the shape contract with Dart's Log.nativeEvent
  // parser (keys: ts/level/category/message/context). Exposed for tests.
  static flutter::EncodableMap BuildPayload(const std::string& level,
                                            const std::string& category,
                                            const std::string& message,
                                            const std::string& ts_iso8601);

 private:
  NativeLogPublisher() = default;

  void Emit(const char* level, const std::string& category,
            const std::string& message);

  mutable std::mutex mutex_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_NATIVE_LOG_PUBLISHER_H_
