#ifndef RUNNER_BRIDGE_WORKFLOW_EVENT_PUBLISHER_H_
#define RUNNER_BRIDGE_WORKFLOW_EVENT_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>

#include <memory>
#include <mutex>
#include <string>

// Process-level publisher for the `com.clingfy/workflow/events` event
// channel.
//
// Phase 3E moves the workflow channel off the Phase-0 no-op stub onto a
// real stream handler. The stream handler installs / removes the
// `EventSink` here as Dart subscribes / cancels; the recording engine
// then calls the `Emit*` helpers from the platform thread (where its
// Start / Stop calls run) to push events back to Flutter.
//
// The publisher is intentionally singleton-shaped because the
// `flutter_window` owns the channel registration but the engine — which
// uses function-pointer router handlers — has no other way to reach it.
// All Emit* calls are safe when no Dart listener is attached: events
// are dropped on the floor so a defensive caller never crashes.
namespace clingfy::bridge {

class WorkflowEventPublisher {
 public:
  using EventSink = flutter::EventSink<flutter::EncodableValue>;

  static WorkflowEventPublisher& Instance();

  WorkflowEventPublisher(const WorkflowEventPublisher&) = delete;
  WorkflowEventPublisher& operator=(const WorkflowEventPublisher&) = delete;

  // The stream handler hands the sink in on listen and back to nullptr
  // on cancel. Multiple sequential listens are tolerated — a second
  // listen replaces the first sink.
  void SetSink(std::unique_ptr<EventSink> sink);
  void ClearSink();

  // True when Dart has an active listener. Useful in tests / engine
  // diagnostics; the Emit* methods do not require it (they drop
  // silently when false).
  bool has_sink() const;

  // Recording lifecycle events. Each helper builds an EncodableMap that
  // matches the macOS engine's payload exactly, so the Dart-side
  // listeners (`_handleRecordingStartedEvent`, etc.) work without any
  // Windows-only branching.
  void EmitRecordingStarted(const std::string& session_id);
  void EmitRecordingPaused(const std::string& session_id);
  void EmitRecordingResumed(const std::string& session_id);

  // `project_path` is the absolute path to the `.clingfyproj` folder.
  // Dart requires a non-empty string here or the finalize is treated as
  // a failure.
  void EmitRecordingFinalized(const std::string& session_id,
                              const std::string& project_path);

  // `stage` is `"start"` or `"finalize"`, mirroring macOS. `code` is the
  // structured error code already used elsewhere in the bridge.
  void EmitRecordingFailed(const std::string& session_id,
                           const std::string& stage,
                           const std::string& code,
                           const std::string& message);

  // `code` (Phase 10.2, optional) is a stable machine-readable id —
  // MIC_OPEN_FAILED / MIC_DISCONNECTED / SYSTEM_AUDIO_OPEN_FAILED /
  // SYSTEM_AUDIO_STOPPED / CAMERA_UNAVAILABLE / CAMERA_OPEN_FAILED /
  // CAMERA_DISCONNECTED / ENCODER_VIDEO_ERROR / ENCODER_AUDIO_ERROR /
  // WINDOW_CLOSED_PARTIAL_SAVED / DISPLAY_DISCONNECTED_PARTIAL_SAVED —
  // letting Dart localize the toast and attach the right settings deep
  // link. Empty = legacy message-only payload (macOS localizes natively
  // and never sends a code). Keep the id list in sync with the constants
  // in lib/core/bridges/recording_warning_codes.dart and the code→toast
  // mapping in lib/app/home/home_error_mapper.dart.
  void EmitRecordingWarning(const std::string& session_id,
                            const std::string& message,
                            const std::string& code = std::string());

  // Preview lifecycle events (Step 5.5.3). macOS emits these from
  // InlinePreviewView.swift to drive the Dart workflow state machine
  // (`previewLoading` → `previewReady`, etc.). Windows now mirrors that
  // contract from `PreviewEngine`. Payload shape matches macOS exactly:
  // `{type, sessionId, path}` plus optional `reason` / `code` / `error`.
  void EmitPreviewPreparing(const std::string& session_id,
                            const std::string& project_path);
  void EmitPreviewReady(const std::string& session_id,
                        const std::string& project_path);
  void EmitPreviewClosed(const std::string& session_id,
                         const std::string& project_path,
                         const std::string& reason);
  void EmitPreviewFailed(const std::string& session_id,
                         const std::string& project_path,
                         const std::string& code,
                         const std::string& error);

  // `openProjectRequest` event used by Step 5.6 (`.clingfyproj` Explorer
  // reopen). The bridge's NativeBridge already buffers these on the
  // Dart side until a callback attaches, but the queue-before-sink
  // logic on the native side lives in `ProjectOpenCoordinator`; this
  // helper is the leaf emitter the coordinator calls once the sink is
  // attached.
  //
  // Payload shape mirrors the macOS engine's `AppDelegate` emission:
  //   { "type": "openProjectRequest", "projectPath": "<UTF-8 abs path>" }
  void EmitOpenProjectRequest(const std::string& project_path);

 private:
  WorkflowEventPublisher() = default;

  // Send a pre-built map. Acquires the mutex, snapshots the sink
  // pointer, then calls `Success` outside the lock so a slow Flutter
  // delivery cannot block other Emit* callers.
  void EmitMap(flutter::EncodableMap event);

  mutable std::mutex mutex_;
  std::unique_ptr<EventSink> sink_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_WORKFLOW_EVENT_PUBLISHER_H_
