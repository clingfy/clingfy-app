#include "Bridge/workflow_event_publisher.h"

#include <utility>

#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

namespace {

flutter::EncodableMap MakeEvent(const std::string& type,
                                 const std::string& session_id) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
      {flutter::EncodableValue("sessionId"),
       flutter::EncodableValue(session_id)},
  };
}

}  // namespace

WorkflowEventPublisher& WorkflowEventPublisher::Instance() {
  static WorkflowEventPublisher instance;
  return instance;
}

void WorkflowEventPublisher::SetSink(std::unique_ptr<EventSink> sink) {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_ = std::move(sink);
}

void WorkflowEventPublisher::ClearSink() {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_.reset();
}

bool WorkflowEventPublisher::has_sink() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return sink_ != nullptr;
}

void WorkflowEventPublisher::EmitMap(flutter::EncodableMap event) {
  // Step 5.5.3: route through `PlatformThreadDispatcher` so callers can
  // emit from any thread without violating Flutter's platform-channel
  // contract. The preview lifecycle events (previewReady, previewFailed,
  // previewClosed) fire from `PreviewEngine::HandleVideoFrame` and the
  // WinRT MediaPlayer worker thread; the recording-lifecycle events
  // already fire from the platform thread but routing them through the
  // dispatcher costs nothing and keeps both publishers symmetric.
  //
  // When the dispatcher is not initialized (tests, cold-start race)
  // `Post()` runs the task inline. The drop-when-no-sink check is done
  // both eagerly (fast path) and again at dispatch time so that a
  // subscription cancelled mid-flight does not deliver a stale event.
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sink_ == nullptr) return;
  }
  PlatformThreadDispatcher::Instance().Post(
      [this, event = std::move(event)]() mutable {
        EventSink* sink_snapshot = nullptr;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          sink_snapshot = sink_.get();
        }
        if (sink_snapshot == nullptr) return;
        sink_snapshot->Success(
            flutter::EncodableValue(std::move(event)));
      });
}

void WorkflowEventPublisher::EmitRecordingStarted(
    const std::string& session_id) {
  EmitMap(MakeEvent("recordingStarted", session_id));
}

void WorkflowEventPublisher::EmitRecordingPaused(
    const std::string& session_id) {
  EmitMap(MakeEvent("recordingPaused", session_id));
}

void WorkflowEventPublisher::EmitRecordingResumed(
    const std::string& session_id) {
  EmitMap(MakeEvent("recordingResumed", session_id));
}

void WorkflowEventPublisher::EmitRecordingFinalized(
    const std::string& session_id, const std::string& project_path) {
  auto event = MakeEvent("recordingFinalized", session_id);
  event[flutter::EncodableValue("projectPath")] =
      flutter::EncodableValue(project_path);
  EmitMap(std::move(event));
}

void WorkflowEventPublisher::EmitRecordingFailed(
    const std::string& session_id,
    const std::string& stage,
    const std::string& code,
    const std::string& message) {
  auto event = MakeEvent("recordingFailed", session_id);
  event[flutter::EncodableValue("stage")] = flutter::EncodableValue(stage);
  event[flutter::EncodableValue("code")] = flutter::EncodableValue(code);
  // `error` is the macOS payload key Dart reads for the message string.
  // Keep it identical even though "error" reads oddly inside a payload
  // that's already an error — changing the key would force a
  // Windows-only branch in the Dart listener.
  event[flutter::EncodableValue("error")] = flutter::EncodableValue(message);
  EmitMap(std::move(event));
}

void WorkflowEventPublisher::EmitRecordingWarning(
    const std::string& session_id, const std::string& message) {
  auto event = MakeEvent("recordingWarning", session_id);
  event[flutter::EncodableValue("message")] =
      flutter::EncodableValue(message);
  EmitMap(std::move(event));
}

void WorkflowEventPublisher::EmitPreviewPreparing(
    const std::string& session_id, const std::string& project_path) {
  auto event = MakeEvent("previewPreparing", session_id);
  event[flutter::EncodableValue("path")] =
      flutter::EncodableValue(project_path);
  EmitMap(std::move(event));
}

void WorkflowEventPublisher::EmitPreviewReady(
    const std::string& session_id, const std::string& project_path) {
  auto event = MakeEvent("previewReady", session_id);
  event[flutter::EncodableValue("path")] =
      flutter::EncodableValue(project_path);
  EmitMap(std::move(event));
}

void WorkflowEventPublisher::EmitPreviewClosed(
    const std::string& session_id,
    const std::string& project_path,
    const std::string& reason) {
  auto event = MakeEvent("previewClosed", session_id);
  event[flutter::EncodableValue("path")] =
      flutter::EncodableValue(project_path);
  event[flutter::EncodableValue("reason")] = flutter::EncodableValue(reason);
  EmitMap(std::move(event));
}

void WorkflowEventPublisher::EmitPreviewFailed(
    const std::string& session_id,
    const std::string& project_path,
    const std::string& code,
    const std::string& error) {
  auto event = MakeEvent("previewFailed", session_id);
  event[flutter::EncodableValue("path")] =
      flutter::EncodableValue(project_path);
  event[flutter::EncodableValue("code")] = flutter::EncodableValue(code);
  // macOS uses the `error` key (not `message`) for the human-readable
  // string. Keep parity so the Dart handler does not need a branch.
  event[flutter::EncodableValue("error")] = flutter::EncodableValue(error);
  EmitMap(std::move(event));
}

}  // namespace clingfy::bridge
