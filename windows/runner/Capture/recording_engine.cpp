#include "Capture/recording_engine.h"

#include "Bridge/Devices/display_enumerator.h"
#include "Bridge/native_error_codes.h"
#include "Capture/video_frame_queue.h"
#include "Capture/wgc_display_capture_backend.h"
#include "Capture/windows_selection_state.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture {

RecordingEngine& RecordingEngine::Instance() {
  static RecordingEngine engine;
  return engine;
}

RecordingEngine::RecordingEngine() = default;
RecordingEngine::~RecordingEngine() = default;

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

  // Phase 3B capability gate: only display recording is supported. Future
  // sub-phases will widen this — window/area/follow-mouse/mouse-at-start
  // each need their own capture pipeline.
  const DisplayTargetMode mode =
      WindowsSelectionState::Instance().TargetMode();
  if (mode != DisplayTargetMode::kExplicitId) {
    return RecordingError{
        clingfy::bridge::error::kBadMode,
        std::string("Target mode '") + TargetModeName(mode) +
            "' is not supported on Windows yet. Phase 3B only supports "
            "explicit-display recording."};
  }

  // Resolve the selected display to an HMONITOR. A null selection falls
  // back to the primary monitor for a friendlier first-run experience.
  const auto display_id = WindowsSelectionState::Instance().DisplayId();
  const auto monitor =
      clingfy::bridge::devices::ResolveHMonitor(display_id);
  if (!monitor) {
    return RecordingError{
        clingfy::bridge::error::kTargetError,
        "No display available to record. Plug in a monitor, or pick one "
        "in the display selector."};
  }

  if (!session_.BeginStart(request.session_id)) {
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Starting state."};
  }

  // Spin up D3D + WGC. On failure, tear the partial pipeline down and
  // mark the session failed so a defensive caller doesn't get stuck in a
  // Starting state.
  d3d_device_ = std::make_unique<clingfy::graphics::D3DDevice>();
  if (auto d3d_err = d3d_device_->Create()) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return RecordingError{clingfy::bridge::error::kRecordingError,
                          d3d_err->message};
  }

  frame_queue_ = std::make_unique<VideoFrameQueue>(/*capacity=*/60);
  capture_backend_ = std::make_unique<WgcDisplayCaptureBackend>();
  if (auto wgc_err =
          capture_backend_->Start(*monitor, *d3d_device_, *frame_queue_)) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return RecordingError{clingfy::bridge::error::kRecordingError,
                          wgc_err->message};
  }

  clock_.MarkStart();

  if (!session_.MarkStarted()) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
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
    return std::nullopt;
  }

  if (!session_id.empty() && !session_.session_id().empty() &&
      session_id != session_.session_id()) {
    return RecordingError{
        clingfy::bridge::error::kInvalidRecordingState,
        "stopRecording sessionId does not match the active session."};
  }

  if (session_.state() == RecordingState::kStopped ||
      session_.state() == RecordingState::kFailed) {
    TeardownPipeline();
    session_.Reset();
    return std::nullopt;
  }

  if (!session_.BeginStop()) {
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Cannot stop a session that has not finished "
                          "starting."};
  }

  TeardownPipeline();

  if (!session_.MarkStopped()) {
    session_.MarkFailed();
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Stopped state."};
  }
  session_.Reset();
  return std::nullopt;
}

void RecordingEngine::TeardownPipeline() {
  // Order matters: stop pushing frames first, then close the queue so any
  // future Phase 3C drain thread wakes and exits, then drop the D3D
  // device. Owning unique_ptr resets are safe-to-call-twice so a
  // failure-path caller does not have to be defensive.
  if (capture_backend_) {
    capture_backend_->Stop();
    capture_backend_.reset();
  }
  if (frame_queue_) {
    frame_queue_->Close();
    frame_queue_.reset();
  }
  if (d3d_device_) {
    d3d_device_->Reset();
    d3d_device_.reset();
  }
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

RecordingEngine::CaptureDiagnostics RecordingEngine::Diagnostics() const {
  std::lock_guard<std::mutex> lock(mutex_);
  CaptureDiagnostics out;
  if (capture_backend_) {
    const auto stats = capture_backend_->Stats();
    out.frame_width = stats.frame_width;
    out.frame_height = stats.frame_height;
    out.frames_received = stats.frames_received;
  }
  if (frame_queue_) {
    out.frames_dropped = frame_queue_->dropped_frame_count();
  }
  return out;
}

void RecordingEngine::ForceResetForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  TeardownPipeline();
  session_ = RecordingSessionState{};
  clock_ = RecordingClock{};
}

}  // namespace clingfy::capture
