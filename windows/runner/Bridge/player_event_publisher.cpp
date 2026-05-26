#include "Bridge/player_event_publisher.h"

#include <utility>

namespace clingfy::bridge {

namespace {

// Build the common {type, sessionId} preamble every payload starts
// with on the macOS side (`emitPlayerEvent` in InlinePreviewView.swift
// always tags sessionId; we mirror that on the wire).
flutter::EncodableMap MakeEvent(const std::string& type,
                                 const std::string& session_id) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
      {flutter::EncodableValue("sessionId"),
       flutter::EncodableValue(session_id)},
  };
}

}  // namespace

PlayerEventPublisher& PlayerEventPublisher::Instance() {
  static PlayerEventPublisher instance;
  return instance;
}

void PlayerEventPublisher::SetSink(std::unique_ptr<EventSink> sink) {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_ = std::move(sink);
}

void PlayerEventPublisher::ClearSink() {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_.reset();
}

bool PlayerEventPublisher::has_sink() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return sink_ != nullptr;
}

void PlayerEventPublisher::EmitMap(flutter::EncodableMap event) {
  // Snapshot the raw pointer under the mutex but release the lock
  // before calling into Success — Flutter's sink delivery can block
  // on the platform thread's message pump, and we don't want to gate
  // other emits on that.
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

void PlayerEventPublisher::EmitPlayerTick(const std::string& session_id,
                                          std::int64_t position_ms,
                                          std::int64_t duration_ms) {
  auto event = MakeEvent("playerTick", session_id);
  event[flutter::EncodableValue("positionMs")] =
      flutter::EncodableValue(position_ms);
  event[flutter::EncodableValue("durationMs")] =
      flutter::EncodableValue(duration_ms);
  EmitMap(std::move(event));
}

void PlayerEventPublisher::EmitPlayerState(const std::string& session_id,
                                           const std::string& state) {
  auto event = MakeEvent("playerState", session_id);
  event[flutter::EncodableValue("state")] = flutter::EncodableValue(state);
  EmitMap(std::move(event));
}

void PlayerEventPublisher::EmitPlayerError(const std::string& session_id,
                                           const std::string& code,
                                           const std::string& message) {
  auto event = MakeEvent("playerError", session_id);
  event[flutter::EncodableValue("code")] = flutter::EncodableValue(code);
  event[flutter::EncodableValue("message")] =
      flutter::EncodableValue(message);
  EmitMap(std::move(event));
}

void PlayerEventPublisher::EmitPlayerWarning(const std::string& session_id,
                                             const std::string& code,
                                             const std::string& message) {
  auto event = MakeEvent("playerWarning", session_id);
  event[flutter::EncodableValue("code")] = flutter::EncodableValue(code);
  event[flutter::EncodableValue("message")] =
      flutter::EncodableValue(message);
  EmitMap(std::move(event));
}

}  // namespace clingfy::bridge
