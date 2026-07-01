#ifndef RUNNER_CAPTURE_RECORDING_SESSION_STATE_H_
#define RUNNER_CAPTURE_RECORDING_SESSION_STATE_H_

#include <string>
#include <string_view>

// Pure-logic state machine for a single recording session.
//
// Phase 3A introduces it as the engine's source of truth for "is a recording
// in progress, and which session id owns it". Capture, encoding, and audio
// pipelines land in later sub-phases; they all transition state through this
// class so a programming bug surfaces as a structured error rather than a
// half-baked MP4 on disk.
//
// State diagram (Phase 4 adds Pausing / Paused / Resuming):
//
//   Idle -> Starting -> Recording <-+-> Pausing -> Paused
//     ^         \           \      |                 |
//     |          \           \     +- Resuming <-----+
//     |           \           \           ↓
//     |            \           Stopping -> Stopped -+
//     |             \                              |
//     |              +-------- Failed --+          |
//     +------------------------------------+-------+
//                              (Reset)
//
// Stop is reachable from both Recording AND Paused — the engine
// finalizes a paused recording into a (shorter) MP4 rather than
// refusing the call.
//
// The transitions are intentionally narrow: callers can only move forward
// through the lifecycle, fail out from any active state, or `Reset` back
// to `Idle` once the session has reached a terminal state. Illegal
// transitions return `false` instead of throwing — the engine maps that
// into a structured `ALREADY_RECORDING` / `NOT_RECORDING` /
// `INVALID_RECORDING_STATE` error for Dart.
namespace clingfy::capture {

enum class RecordingState {
  kIdle,
  kStarting,
  kRecording,
  kPausing,
  kPaused,
  kResuming,
  kStopping,
  kStopped,
  kFailed,
};

const char* ToString(RecordingState state);

class RecordingSessionState {
 public:
  RecordingState state() const { return state_; }
  std::string_view session_id() const { return session_id_; }

  // True while a session is in flight (Starting / Recording / Pausing /
  // Paused / Resuming / Stopping). Used by the engine to reject `Start`
  // while another session is active and to short-circuit `Stop` when
  // nothing is running.
  bool IsActive() const;

  // True while the session is paused or pausing — Phase 4 uses this to
  // gate pause/resume idempotency at the engine level.
  bool IsPausedOrPausing() const;

  // Idle -> Starting. Returns false if the state machine is anywhere other
  // than Idle / Stopped / Failed (a terminal state can be reused for the
  // next session).
  bool BeginStart(std::string session_id);

  // Starting -> Recording. Returns false if not in Starting. Called once
  // the underlying capture + encoder pipeline has been spun up; Phase 3A
  // calls it synchronously inside `Start` because the skeleton has no
  // asynchronous setup yet.
  bool MarkStarted();

  // Recording -> Pausing -> Paused. Each helper returns false if the
  // state machine refuses the transition (e.g. BeginPause from
  // anything other than Recording). Phase 4 uses these to drive the
  // capture pipeline + clock pause / resume.
  bool BeginPause();
  bool MarkPaused();
  bool BeginResume();
  bool MarkResumed();

  // Recording -> Stopping, OR Paused -> Stopping. Returns false
  // otherwise. The engine treats a false return as "nothing to stop"
  // (idempotent stop) rather than an error. Stop-from-Paused is the
  // user finalizing a paused recording without resuming first; we
  // accept it and produce a shorter MP4 instead of refusing.
  bool BeginStop();

  // Stopping -> Stopped. Clears the session id.
  bool MarkStopped();

  // Any active state -> Failed. Used when the encoder or capture pipeline
  // reports an unrecoverable error mid-session. Idempotent.
  void MarkFailed();

  // Stopped / Failed -> Idle. Engine calls this once the terminal-state
  // metadata has been read by the caller; resets `session_id` to empty.
  bool Reset();

 private:
  RecordingState state_ = RecordingState::kIdle;
  std::string session_id_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_SESSION_STATE_H_
