#include "Capture/recording_engine.h"

#include "Bridge/native_error_codes.h"

namespace clingfy::capture {

RecordingEngine& RecordingEngine::Instance() {
  static RecordingEngine engine;
  return engine;
}

std::optional<RecordingError> RecordingEngine::Start(
    StartRecordingRequest request) {
  std::lock_guard<std::mutex> lock(mutex_);

  if (request.session_id.empty()) {
    return RecordingError{clingfy::bridge::error::kBadArgs,
                          "startRecording requires a non-empty sessionId."};
  }
  if (request.frame_rate <= 0) {
    return RecordingError{
        clingfy::bridge::error::kBadArgs,
        "startRecording frameRate must be a positive integer."};
  }

  if (session_.IsActive()) {
    return RecordingError{
        clingfy::bridge::error::kAlreadyRecording,
        "A recording session is already in flight; stop it before "
        "starting another."};
  }

  if (!session_.BeginStart(request.session_id)) {
    // BeginStart only refuses while a session is already active, which we
    // checked above. Reaching here would be a programming error in the
    // state machine.
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Starting state."};
  }

  // Phase 3A skeleton: no capture pipeline to spin up, so the start
  // handshake completes synchronously. Phase 3B/C/D will move this between
  // the BeginStart and MarkStarted calls.
  clock_.MarkStart();

  if (!session_.MarkStarted()) {
    session_.MarkFailed();
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Recording state."};
  }
  return std::nullopt;
}

std::optional<RecordingError> RecordingEngine::Stop(
    const std::string& session_id) {
  std::lock_guard<std::mutex> lock(mutex_);

  if (!session_.IsActive() && session_.state() != RecordingState::kStopped &&
      session_.state() != RecordingState::kFailed) {
    // Nothing to stop — treat as success so a defensive double-stop from
    // Dart does not surface a confusing toast.
    return std::nullopt;
  }

  // If the caller quotes a session id at all, it must match. A blank id is
  // tolerated for backward compatibility with the older Phase 1 stub
  // behavior, where stopRecording carried no payload.
  if (!session_id.empty() && !session_.session_id().empty() &&
      session_id != session_.session_id()) {
    return RecordingError{
        clingfy::bridge::error::kInvalidRecordingState,
        "stopRecording sessionId does not match the active session."};
  }

  if (session_.state() == RecordingState::kStopped ||
      session_.state() == RecordingState::kFailed) {
    session_.Reset();
    return std::nullopt;
  }

  if (!session_.BeginStop()) {
    // BeginStop only refuses outside of Recording. The only active state
    // not covered is Starting, which Phase 3A reaches transiently inside
    // Start (under the same lock) — so reaching here in practice means an
    // illegal external transition.
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Cannot stop a session that has not finished "
                          "starting."};
  }

  // Phase 3A skeleton: no capture pipeline to tear down, so the stop
  // handshake completes synchronously. Phase 3B/C/D will move encoder
  // finalize + capture teardown between BeginStop and MarkStopped.
  if (!session_.MarkStopped()) {
    session_.MarkFailed();
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Stopped state."};
  }
  session_.Reset();
  return std::nullopt;
}

bool RecordingEngine::IsRecording() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return session_.state() == RecordingState::kRecording;
}

RecordingState RecordingEngine::state() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return session_.state();
}

std::string RecordingEngine::session_id() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return std::string(session_.session_id());
}

void RecordingEngine::ForceResetForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  session_ = RecordingSessionState{};
  clock_ = RecordingClock{};
}

}  // namespace clingfy::capture
