#include "Bridge/workflow_event_publisher.h"

#include <utility>

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
  // Snapshot the raw pointer under the mutex but release the lock before
  // calling into Success — Flutter's sink delivery can block on the
  // platform thread's message pump, and we don't want to gate other
  // emits on that.
  EventSink* sink_snapshot = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_snapshot = sink_.get();
  }
  if (sink_snapshot == nullptr) {
    // No listener — drop the event. Matches the macOS engine's
    // best-effort behavior when the Flutter side hasn't subscribed yet.
    return;
  }
  sink_snapshot->Success(flutter::EncodableValue(std::move(event)));
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

}  // namespace clingfy::bridge
