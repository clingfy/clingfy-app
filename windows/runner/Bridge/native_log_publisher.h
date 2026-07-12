#ifndef RUNNER_BRIDGE_NATIVE_LOG_PUBLISHER_H_
#define RUNNER_BRIDGE_NATIVE_LOG_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <deque>
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
// PlatformThreadDispatcher.
//
// Emits with no channel attached are held in a bounded pending buffer
// (drop-oldest) instead of being dropped, and drained when Dart signals its
// 'log' handler is installed (the `flushPendingNativeLogs` bridge call) — so
// startup diagnostics (device enumeration, recovery sweep) reach the unified
// log file. Mirrors macOS `NativeLogger`'s pending buffer.
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

  // DEBUG is dropped at the source unless the current threshold allows it (the
  // Settings "verbose logging" toggle, via SetMinLevel), so verbose per-feature
  // tracing never crosses the channel or reaches release users' logs/Sentry.
  //
  // `context` carries structured key/values (mirrors the macOS NativeLogger
  // context parameter); put the failure text in `error` (and a trace in
  // `stack`) on Error calls so Dart's Sentry sink promotes a native ERROR to
  // a real exception with that text.
  void Debug(const std::string& category, const std::string& message,
             flutter::EncodableMap context = {});
  void Info(const std::string& category, const std::string& message,
            flutter::EncodableMap context = {});
  void Warn(const std::string& category, const std::string& message,
            flutter::EncodableMap context = {});
  void Error(const std::string& category, const std::string& message,
             flutter::EncodableMap context = {},
             const std::string& error_text = {},
             const std::string& stack = {});

  // Set the minimum emitted level from a level name (debug/info/warning/error;
  // also d/i/w/e, verbose/trace). Unknown names are ignored. Driven by Dart's
  // `setNativeLogLevel` (the Settings "verbose logging" toggle), mirroring macOS
  // `NativeLogger.setMinLevel`. Thread-safe.
  void SetMinLevel(const std::string& level_name);

  // Whether an emitted level ("DEBUG"/"INFO"/"WARNING"/"ERROR") passes the
  // current threshold. Below-threshold logs are dropped at the source. Exposed
  // for tests.
  bool ShouldSend(const std::string& emitted_level) const;
  int min_level_rank() const { return min_level_rank_.load(); }

  // Drains the pending (pre-channel) buffer through the channel, oldest
  // first. Called by the `flushPendingNativeLogs` bridge handler once Dart's
  // 'log' handler is installed. No-op (buffer retained) while no channel is
  // attached.
  void FlushPending();

  // Number of buffered lines waiting for FlushPending. Exposed for tests.
  size_t pending_count() const;

  // Test-only: empty the pending buffer so singleton state can't leak
  // between tests.
  void ClearPendingForTest();

  // Test-only: copy of the oldest buffered payload ({} when empty), so tests
  // can pin what a buffered line actually carries.
  flutter::EncodableMap FrontPendingForTest() const;

  // Oldest lines beyond this are dropped — a startup burst can't grow
  // unbounded if the Flutter engine never attaches.
  static constexpr size_t kMaxPending = 512;

  // Pure payload builder — the shape contract with Dart's Log.nativeEvent
  // parser (keys: ts/level/category/message/context, plus error/stack only
  // when non-empty). Exposed for tests.
  static flutter::EncodableMap BuildPayload(const std::string& level,
                                            const std::string& category,
                                            const std::string& message,
                                            const std::string& ts_iso8601,
                                            flutter::EncodableMap context = {},
                                            const std::string& error_text = {},
                                            const std::string& stack = {});

 private:
  NativeLogPublisher();

  void Emit(const char* level, const std::string& category,
            const std::string& message, flutter::EncodableMap context = {},
            const std::string& error_text = {}, const std::string& stack = {});

  // Posts one payload to the platform thread and invokes the reverse 'log'
  // call (re-checking the channel inside the posted task).
  void PostToChannel(flutter::EncodableMap payload);

  mutable std::mutex mutex_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
  // Lines emitted while no channel was attached, oldest first (bounded by
  // kMaxPending, drop-oldest). Guarded by mutex_.
  std::deque<flutter::EncodableMap> pending_;
  // Min emitted level as a rank (debug=0 < info=1 < warning=2 < error=3),
  // resolved once from CLINGFY_LOG_LEVEL / the build default, then adjusted at
  // runtime by SetMinLevel. Atomic: read on the emitting thread, written on the
  // platform thread.
  std::atomic<int> min_level_rank_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_NATIVE_LOG_PUBLISHER_H_
