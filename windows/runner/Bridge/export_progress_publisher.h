#ifndef RUNNER_BRIDGE_EXPORT_PROGRESS_PUBLISHER_H_
#define RUNNER_BRIDGE_EXPORT_PROGRESS_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <mutex>

// Process-level publisher for export progress (Phase 6 Slice 5A).
//
// Unlike the player/workflow publishers (which push onto EVENT channels),
// export progress is delivered by a reverse METHOD-channel call:
// `channel.invokeMethod("updateExportProgress", <map>)` — exactly what macOS
// does (MainFlutterWindow `self.channel?.invokeMethod`). Dart listens for it on
// the screen_recorder method channel and parses it through
// `lib/core/bridges/job_progress.dart`.
//
// The payload is a LABELLED MAP, not a bare double:
//
//     { "job": "export", "stage": "rendering", "fraction": 0.0..1.0 }
//
// `fraction` is OMITTED when indeterminate, never sent as null or zero — zero
// is a real value meaning "just started".
//
// It carried a bare double until captions needed to report progress on the same
// channel: one anonymous number cannot say which job is running or which phase
// it is in, and a bar sitting near zero while audio decodes is indistinguishable
// from a hang. Three runtimes implement this shape (here, macOS
// Runner/Core/JobProgress.swift, and the Dart parser); the wire strings are
// pinned by test on the Dart side, so a rename here silently freezes the
// Windows progress bar rather than failing loudly.
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
