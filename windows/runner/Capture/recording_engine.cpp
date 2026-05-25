#include "Capture/recording_engine.h"

#include <thread>
#include <utility>

#include "Audio/audio_mixer.h"
#include "Audio/audio_packet.h"
#include "Audio/audio_packet_queue.h"
#include "Audio/wasapi_audio_capture.h"
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
  if (audio_mixer_thread_.joinable()) {
    audio_mixer_stopped_.store(true);
    if (mic_queue_) mic_queue_->Close();
    if (loopback_queue_) loopback_queue_->Close();
    audio_mixer_thread_.join();
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
            "' is not supported on Windows yet. Phase 3D only supports "
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

  // Resolve monitor dimensions ahead of the encoder open so the
  // recording resolution matches the source.
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

  // Decide whether to ship an audio stream. Both gates have to clear:
  // mic must not be explicitly disabled by Dart, AND/OR system audio
  // must be enabled. If both are off, the recording is video-only.
  const bool want_mic = !request.disable_microphone;
  const bool want_loopback = request.system_audio_enabled;
  std::optional<clingfy::encoding::AudioEncoderConfig> audio_config;
  if (want_mic || want_loopback) {
    audio_config = clingfy::encoding::AudioEncoderConfig{};
  }

  encoder_ =
      std::make_unique<clingfy::encoding::MfSinkWriterEncoder>();
  if (auto enc_err = encoder_->Open(encoder_config, *d3d_device_,
                                      audio_config)) {
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

  // Audio captures: each is best-effort. If mic open fails we log and
  // continue with loopback only; if loopback fails we continue with mic
  // only. Both failing isn't a hard error either — the recording still
  // produces a video-only MP4, which is the macOS engine's behavior on
  // a host with no audio devices.
  if (want_mic) {
    mic_queue_ = std::make_unique<clingfy::audio::AudioPacketQueue>();
    mic_capture_ =
        std::make_unique<clingfy::audio::WasapiAudioCapture>();
    const auto mic_id =
        WindowsSelectionState::Instance().MicrophoneId().value_or("");
    if (mic_capture_->Start(
            clingfy::audio::WasapiCaptureKind::kMicrophone, mic_id,
            *mic_queue_)) {
      mic_capture_.reset();
      mic_queue_.reset();
    }
  }
  if (want_loopback) {
    loopback_queue_ =
        std::make_unique<clingfy::audio::AudioPacketQueue>();
    loopback_capture_ =
        std::make_unique<clingfy::audio::WasapiAudioCapture>();
    if (loopback_capture_->Start(
            clingfy::audio::WasapiCaptureKind::kSystemLoopback, "",
            *loopback_queue_)) {
      loopback_capture_.reset();
      loopback_queue_.reset();
    }
  }

  // Drain thread: pulls captured frames off the queue and writes them
  // to the encoder.
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

  // Audio mixer thread: pulls one packet at a time from whichever
  // queue(s) are alive, mixes (or pass-through when a source is
  // missing), and forwards to the encoder. Skipped entirely when both
  // captures failed or both were disabled.
  if (mic_capture_ != nullptr || loopback_capture_ != nullptr) {
    audio_mixer_stopped_.store(false);
    audio_mixer_thread_ = std::thread([this] {
      clingfy::audio::AudioMixer mixer;
      while (!audio_mixer_stopped_.load()) {
        std::optional<clingfy::audio::AudioPacket> mic;
        std::optional<clingfy::audio::AudioPacket> loopback;
        if (mic_queue_ != nullptr) {
          mic = mic_queue_->Pop();
          if (audio_mixer_stopped_.load()) break;
        }
        if (loopback_queue_ != nullptr) {
          // Use TryPop when the mic queue is alive so we don't block
          // waiting for system audio if nothing is currently playing.
          // When only loopback is alive (no mic), fall back to a
          // blocking Pop so the mixer doesn't busy-spin.
          if (mic_queue_ != nullptr) {
            loopback = loopback_queue_->TryPop();
          } else {
            loopback = loopback_queue_->Pop();
            if (audio_mixer_stopped_.load()) break;
          }
        }
        if (!mic.has_value() && !loopback.has_value()) {
          // Both queues drained / closed → exit the mixer loop.
          break;
        }
        auto mixed = mixer.Mix(mic.has_value() ? &*mic : nullptr,
                                loopback.has_value() ? &*loopback : nullptr);
        if (mixed.frame_count > 0 && encoder_ != nullptr) {
          encoder_->WriteAudioPacket(mixed);
        }
      }
    });
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
  // Strict ordering: stop the capture producers first, then signal the
  // drain / mixer consumer threads via queue Close, join them, then
  // finalize the encoder so the MP4 footer is written before the
  // device that backs its DXGI manager goes away.
  if (capture_backend_) {
    capture_backend_->Stop();
    capture_backend_.reset();
  }
  if (mic_capture_) {
    mic_capture_->Stop();
    mic_capture_.reset();
  }
  if (loopback_capture_) {
    loopback_capture_->Stop();
    loopback_capture_.reset();
  }

  encoder_stopped_.store(true);
  audio_mixer_stopped_.store(true);
  if (frame_queue_) frame_queue_->Close();
  if (mic_queue_) mic_queue_->Close();
  if (loopback_queue_) loopback_queue_->Close();
  if (encoder_thread_.joinable()) encoder_thread_.join();
  if (audio_mixer_thread_.joinable()) audio_mixer_thread_.join();

  if (encoder_) {
    encoder_->Finalize();
    encoder_.reset();
  }
  if (frame_queue_) frame_queue_.reset();
  if (mic_queue_) mic_queue_.reset();
  if (loopback_queue_) loopback_queue_.reset();
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
  if (mic_capture_) {
    out.mic_active = mic_capture_->running();
    out.mic_packets = mic_capture_->packets_emitted();
  }
  if (loopback_capture_) {
    out.loopback_active = loopback_capture_->running();
    out.loopback_packets = loopback_capture_->packets_emitted();
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
