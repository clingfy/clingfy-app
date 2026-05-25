#include "Capture/recording_engine.h"

#include <thread>
#include <utility>

#include "Bridge/Devices/display_enumerator.h"
#include "Bridge/native_error_codes.h"
#include "Capture/captured_video_frame.h"
#include "Capture/video_frame_queue.h"
#include "Capture/wgc_display_capture_backend.h"
#include "Capture/windows_selection_state.h"
#include "Encoding/encoder_output_path.h"
#include "Encoding/mf_encoder_config.h"
#include "Encoding/mf_sink_writer_encoder.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture {

namespace {

// Round an odd dimension up to the next even value. H.264 requires even
// frame dimensions; rather than refusing the recording when a monitor's
// native size happens to be odd, the engine clamps up by one pixel so
// the encoder configuration is always valid.
std::uint32_t RoundUpToEven(std::uint32_t value) {
  return value + (value & 1u);
}

}  // namespace

RecordingEngine& RecordingEngine::Instance() {
  static RecordingEngine engine;
  return engine;
}

RecordingEngine::RecordingEngine() = default;

RecordingEngine::~RecordingEngine() {
  // Defensive teardown — the engine is a Meyers singleton so this only
  // fires at process exit. Joining the encoder thread here keeps a
  // dangling recording from outliving the engine.
  if (encoder_thread_.joinable()) {
    if (frame_queue_) {
      frame_queue_->Close();
    }
    encoder_thread_.join();
  }
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

  const DisplayTargetMode mode =
      WindowsSelectionState::Instance().TargetMode();
  if (mode != DisplayTargetMode::kExplicitId) {
    return RecordingError{
        clingfy::bridge::error::kBadMode,
        std::string("Target mode '") + TargetModeName(mode) +
            "' is not supported on Windows yet. Phase 3C only supports "
            "explicit-display recording."};
  }

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

  d3d_device_ = std::make_unique<clingfy::graphics::D3DDevice>();
  if (auto d3d_err = d3d_device_->Create()) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return RecordingError{clingfy::bridge::error::kRecordingError,
                          d3d_err->message};
  }

  // Resolve the monitor's pixel dimensions ahead of the encoder open so
  // the recording resolution matches the source. WGC reports the size on
  // the first FrameArrived; for the encoder we need it up front, so we
  // pull it from `GetMonitorInfoW` here.
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  std::uint32_t width = 1920;
  std::uint32_t height = 1080;
  if (::GetMonitorInfoW(*monitor, &info) != 0) {
    width = static_cast<std::uint32_t>(info.rcMonitor.right -
                                        info.rcMonitor.left);
    height = static_cast<std::uint32_t>(info.rcMonitor.bottom -
                                         info.rcMonitor.top);
  }

  clingfy::encoding::EncoderConfig encoder_config;
  encoder_config.width = RoundUpToEven(width);
  encoder_config.height = RoundUpToEven(height);
  encoder_config.fps = static_cast<std::uint32_t>(request.frame_rate);
  encoder_config.output_path =
      clingfy::encoding::ResolveTempMp4Path(request.session_id);

  encoder_ =
      std::make_unique<clingfy::encoding::MfSinkWriterEncoder>();
  if (auto enc_err = encoder_->Open(encoder_config, *d3d_device_)) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return RecordingError{clingfy::bridge::error::kRecordingError,
                          enc_err->message};
  }
  current_output_path_ = encoder_config.output_path;

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

  // Drain thread: pulls captured frames off the queue and writes them to
  // the encoder. `Pop` blocks until either a frame is available or the
  // queue is closed (signalled by `TeardownPipeline` during Stop).
  encoder_stopped_.store(false);
  encoder_thread_ = std::thread([this] {
    auto* queue = frame_queue_.get();
    auto* encoder = encoder_.get();
    if (queue == nullptr || encoder == nullptr) {
      return;
    }
    while (auto frame = queue->Pop()) {
      if (encoder_stopped_.load()) {
        break;
      }
      encoder->WriteVideoFrame(*frame);
    }
  });

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
  // Strict ordering: stop producing frames first (WGC), then signal the
  // drain thread to exit by closing the queue, then join the thread,
  // THEN finalize the encoder so the MP4 footer is written before the
  // D3D device that backs its DXGI manager goes away.
  if (capture_backend_) {
    capture_backend_->Stop();
    capture_backend_.reset();
  }
  encoder_stopped_.store(true);
  if (frame_queue_) {
    frame_queue_->Close();
  }
  if (encoder_thread_.joinable()) {
    encoder_thread_.join();
  }
  if (encoder_) {
    encoder_->Finalize();
    encoder_.reset();
  }
  if (frame_queue_) {
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
  if (encoder_) {
    out.samples_written = encoder_->samples_written();
    out.output_path = encoder_->output_path();
  } else {
    out.output_path = current_output_path_;
  }
  return out;
}

void RecordingEngine::ForceResetForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  TeardownPipeline();
  session_ = RecordingSessionState{};
  clock_ = RecordingClock{};
  current_output_path_.clear();
}

}  // namespace clingfy::capture
