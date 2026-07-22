#include "Bridge/player_event_publisher.h"

#include <utility>

#include "Bridge/platform_thread_dispatcher.h"

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
  // EmitMap may be called from a WinRT worker thread (the
  // VideoFrameAvailable / PlaybackStateChanged / MediaEnded /
  // MediaFailed callbacks) or from the producer heartbeat thread,
  // neither of which is the Flutter platform thread. Flutter's
  // platform-channel contract requires EventSink::Success() to land
  // on the platform thread; routing through PlatformThreadDispatcher
  // satisfies that without forcing every caller to know which thread
  // they are on.
  //
  // The dispatcher is initialized once at FlutterWindow startup. When
  // it isn't initialized (tests, or a pathological cold-start race),
  // Dispatcher::Post() runs the task inline — preserving event
  // delivery and the synchronous behaviour the publisher unit tests
  // depend on.
  //
  // Drop-when-no-sink is checked twice: once eagerly here to avoid
  // posting a no-op task, and again at dispatch time in case Dart
  // cancels the subscription between Emit and the platform-thread
  // dispatch. The second check is strictly necessary for correctness;
  // the first is purely a fast path.
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sink_ == nullptr) return;
  }
  PlatformThreadDispatcher::Instance().Post(
      [this, event = std::move(event)]() mutable {
        // Runs on the Flutter platform thread (or inline if the
        // dispatcher wasn't initialized). Look up the sink fresh —
        // SetSink / ClearSink also run on the platform thread, so
        // there is no concurrent mutation between this lookup and
        // the Success() call.
        EventSink* sink_snapshot = nullptr;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          sink_snapshot = sink_.get();
        }
        if (sink_snapshot == nullptr) {
          // Subscription was cancelled between enqueue and dispatch.
          // Drop on the floor — matches the no-listener policy.
          return;
        }
        sink_snapshot->Success(
            flutter::EncodableValue(std::move(event)));
      });
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

void PlayerEventPublisher::EmitPreviewInvalidated(
    const std::string& session_id, const std::string& reason) {
  auto event = MakeEvent("previewInvalidated", session_id);
  event[flutter::EncodableValue("reason")] = flutter::EncodableValue(reason);
  EmitMap(std::move(event));
}

}  // namespace clingfy::bridge
