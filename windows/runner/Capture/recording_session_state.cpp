#include "Capture/recording_session_state.h"

namespace clingfy::capture {

const char* ToString(RecordingState state) {
  switch (state) {
    case RecordingState::kIdle:
      return "idle";
    case RecordingState::kStarting:
      return "starting";
    case RecordingState::kRecording:
      return "recording";
    case RecordingState::kPausing:
      return "pausing";
    case RecordingState::kPaused:
      return "paused";
    case RecordingState::kResuming:
      return "resuming";
    case RecordingState::kStopping:
      return "stopping";
    case RecordingState::kStopped:
      return "stopped";
    case RecordingState::kFailed:
      return "failed";
  }
  return "unknown";
}

bool RecordingSessionState::IsActive() const {
  return state_ == RecordingState::kStarting ||
         state_ == RecordingState::kRecording ||
         state_ == RecordingState::kPausing ||
         state_ == RecordingState::kPaused ||
         state_ == RecordingState::kResuming ||
         state_ == RecordingState::kStopping;
}

bool RecordingSessionState::IsPausedOrPausing() const {
  return state_ == RecordingState::kPausing ||
         state_ == RecordingState::kPaused;
}

bool RecordingSessionState::BeginStart(std::string session_id) {
  // Stopped / Failed are terminal but reusable — once the caller has
  // consumed the result of the previous session, a new one can start
  // without an explicit Reset.
  if (state_ != RecordingState::kIdle && state_ != RecordingState::kStopped &&
      state_ != RecordingState::kFailed) {
    return false;
  }
  state_ = RecordingState::kStarting;
  session_id_ = std::move(session_id);
  return true;
}

bool RecordingSessionState::MarkStarted() {
  if (state_ != RecordingState::kStarting) {
    return false;
  }
  state_ = RecordingState::kRecording;
  return true;
}

bool RecordingSessionState::BeginPause() {
  if (state_ != RecordingState::kRecording) {
    return false;
  }
  state_ = RecordingState::kPausing;
  return true;
}

bool RecordingSessionState::MarkPaused() {
  if (state_ != RecordingState::kPausing) {
    return false;
  }
  state_ = RecordingState::kPaused;
  return true;
}

bool RecordingSessionState::BeginResume() {
  if (state_ != RecordingState::kPaused) {
    return false;
  }
  state_ = RecordingState::kResuming;
  return true;
}

bool RecordingSessionState::MarkResumed() {
  if (state_ != RecordingState::kResuming) {
    return false;
  }
  state_ = RecordingState::kRecording;
  return true;
}

bool RecordingSessionState::BeginStop() {
  // Phase 4 widens this from Recording-only to {Recording, Paused}.
  // Stop-from-Paused is a deliberate finalize: the user pressed
  // Pause, decided they're done, and hit Stop without resuming. We
  // accept it and let the engine finalize the partial MP4 rather
  // than refusing the call. Starting / Pausing / Resuming are still
  // illegal because their underlying captures are mid-transition.
  if (state_ != RecordingState::kRecording &&
      state_ != RecordingState::kPaused) {
    return false;
  }
  state_ = RecordingState::kStopping;
  return true;
}

bool RecordingSessionState::MarkStopped() {
  if (state_ != RecordingState::kStopping) {
    return false;
  }
  state_ = RecordingState::kStopped;
  session_id_.clear();
  return true;
}

void RecordingSessionState::MarkFailed() {
  // Failed is reachable from any active state and from Idle (e.g. arg
  // validation failure before the lifecycle starts). Idempotent — calling
  // it twice is harmless so error-handling code can be defensive without
  // tracking a `was_failed` boolean.
  if (state_ == RecordingState::kFailed) {
    return;
  }
  state_ = RecordingState::kFailed;
}

bool RecordingSessionState::Reset() {
  if (state_ != RecordingState::kStopped && state_ != RecordingState::kFailed) {
    return false;
  }
  state_ = RecordingState::kIdle;
  session_id_.clear();
  return true;
}

}  // namespace clingfy::capture
