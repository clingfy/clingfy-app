#ifndef RUNNER_BRIDGE_EXPORT_PROGRESS_PUBLISHER_H_
#define RUNNER_BRIDGE_EXPORT_PROGRESS_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <mutex>

// Process-level publisher for export progress (Phase 6 Slice 5A).
//
// Unlike the player/workflow publishers (which push onto EVENT channels),
// export progress is delivered by a reverse METHOD-channel call:
// `channel.invokeMethod("updateExportProgress", <double 0..1>)` — exactly what
// macOS does (MainFlutterWindow `self.channel?.invokeMethod`). Dart listens
// for it on the screen_recorder method channel (NativeBridge handles
// `updateExportProgress` and reads `call.arguments as double?`), so the
// payload must be a BARE double, never a map.
//
// `flutter_window` hands this singleton the method channel at startup (the
// same one MethodDispatcher owns) and clears it at teardown. The export worker
// thread calls EmitProgress from off the platform thread, so the actual
// InvokeMethod is marshaled back via PlatformThreadDispatcher::Post (Flutter
// requires channel calls on the platform thread). Emits are dropped silently
// when no channel is attached.
namespace clingfy::bridge {

class ExportProgressPublisher {
 public:
  static ExportProgressPublisher& Instance();

  ExportProgressPublisher(const ExportProgressPublisher&) = delete;
  ExportProgressPublisher& operator=(const ExportProgressPublisher&) = delete;

  // Borrow the screen_recorder method channel (owned by MethodDispatcher).
  // Set at FlutterWindow startup, cleared (nullptr) at teardown BEFORE the
  // channel is destroyed.
  void SetChannel(flutter::MethodChannel<flutter::EncodableValue>* channel);
  void ClearChannel();

  // Push a progress fraction (0.0..1.0) to Dart. Safe from any thread; a no-op
  // when no channel is attached (tests / teardown).
  void EmitProgress(double fraction);

 private:
  ExportProgressPublisher() = default;

  mutable std::mutex mutex_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_EXPORT_PROGRESS_PUBLISHER_H_
