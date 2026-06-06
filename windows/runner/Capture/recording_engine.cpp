#include "Capture/recording_engine.h"

#include <cstdio>
#include <thread>
#include <utility>

#include "Audio/audio_mixer.h"
#include "Audio/audio_packet.h"
#include "Audio/audio_packet_queue.h"
#include "Audio/wasapi_audio_capture.h"
#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/Devices/display_enumerator.h"
#include "Bridge/Devices/window_enumerator.h"
#include "Bridge/native_error_codes.h"
#include "Bridge/workflow_event_publisher.h"
#include "Capture/captured_video_frame.h"
#include "Capture/recording_project_writer.h"
#include "Capture/video_frame_queue.h"
#include "Capture/wgc_display_capture_backend.h"
#include "Capture/windows_selection_state.h"
#include "Encoding/encoder_output_path.h"
#include "Encoding/mf_encoder_config.h"
#include "Encoding/mf_sink_writer_encoder.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture {

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
  // Helper for the structured-error early returns below. Captures the
  // request's sessionId so a `recordingFailed` event fires with the
  // exact id Dart used. We emit at "start" stage for everything that
  // refuses the lifecycle transition before MarkStarted; the
  // post-MarkStarted teardown paths emit at "start" too because the
  // recording never actually became visible to the user.
  auto fail_start = [&](const std::string& code,
                        const std::string& msg) -> RecordingError {
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        request.session_id, "start", code, msg);
    return RecordingError{code, msg};
  };

  std::lock_guard<std::mutex> lock(mutex_);

  if (request.session_id.empty()) {
    return fail_start(clingfy::bridge::error::kBadArgs,
                      "startRecording requires a non-empty sessionId.");
  }
  if (request.frame_rate <= 0) {
    return fail_start(
        clingfy::bridge::error::kBadArgs,
        "startRecording frameRate must be a positive integer.");
  }

  if (session_.IsActive()) {
    return fail_start(
        clingfy::bridge::error::kAlreadyRecording,
        "A recording session is already in flight; stop it before "
        "starting another.");
  }

  const DisplayTargetMode mode =
      WindowsSelectionState::Instance().TargetMode();
  // Phase 7.1 lifts the gate for window modes. macOS distinguishes "app (all
  // windows)" from "single window"; WGC captures one HWND, so both map to
  // single-HWND capture of the selected window for the MVP. Area / mouse modes
  // remain unsupported until their slices.
  const bool is_window_mode = (mode == DisplayTargetMode::kAppWindow ||
                               mode == DisplayTargetMode::kSingleAppWindow);
  if (mode != DisplayTargetMode::kExplicitId && !is_window_mode) {
    return fail_start(
        clingfy::bridge::error::kBadMode,
        std::string("Target mode '") + TargetModeName(mode) +
            "' is not supported on Windows yet. Window recording is live; "
            "area and mouse-follow modes land in later slices.");
  }

  // Resolve the target BEFORE any pipeline setup so a missing / stale target
  // fails cleanly. Display: an HMONITOR (nullopt selection => primary).
  // Window: the selected HWND, revalidated (closed window => friendly error).
  std::optional<HMONITOR> monitor;
  std::optional<HWND> window_target;
  if (is_window_mode) {
    const auto window_id = WindowsSelectionState::Instance().AppWindowId();
    if (!window_id) {
      return fail_start(
          clingfy::bridge::error::kTargetError,
          "No window selected to record. Pick a window first.");
    }
    window_target = clingfy::bridge::devices::ResolveAppWindow(window_id);
    if (!window_target) {
      return fail_start(
          clingfy::bridge::error::kTargetError,
          "The selected window is no longer available. Pick it again.");
    }
    current_target_type_ = "window";
    current_window_id_ = window_id;
  } else {
    const auto display_id = WindowsSelectionState::Instance().DisplayId();
    monitor = clingfy::bridge::devices::ResolveHMonitor(display_id);
    if (!monitor) {
      return fail_start(
          clingfy::bridge::error::kTargetError,
          "No display available to record. Plug in a monitor, or pick one "
          "in the display selector.");
    }
    current_target_type_ = "display";
    current_window_id_.reset();
  }

  if (!session_.BeginStart(request.session_id)) {
    return fail_start(clingfy::bridge::error::kInvalidRecordingState,
                      "Engine refused to enter Starting state.");
  }

  d3d_device_ = std::make_unique<clingfy::graphics::D3DDevice>();
  if (auto d3d_err = d3d_device_->Create()) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return fail_start(clingfy::bridge::error::kRecordingError,
                      d3d_err->message);
  }

  // Resolve capture dimensions ahead of the encoder open so the recording
  // resolution matches the source. Display: the monitor rect. Window: the size
  // WGC will deliver for the window item (NOT GetWindowRect, which differs from
  // the WGC surface by the shadow/frame margin and would mis-size the encoder).
  std::uint32_t width = 1920;
  std::uint32_t height = 1080;
  if (is_window_mode) {
    const auto window_size =
        clingfy::capture::ResolveWindowCaptureSize(*window_target);
    if (!window_size) {
      TeardownPipeline();
      session_.MarkFailed();
      session_.Reset();
      return fail_start(
          clingfy::bridge::error::kTargetError,
          "Could not measure the selected window for capture. Pick it "
          "again.");
    }
    width = window_size->width;
    height = window_size->height;
  } else {
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (::GetMonitorInfoW(*monitor, &info) != 0) {
      width = static_cast<std::uint32_t>(info.rcMonitor.right -
                                          info.rcMonitor.left);
      height = static_cast<std::uint32_t>(info.rcMonitor.bottom -
                                           info.rcMonitor.top);
    }
  }

  clingfy::encoding::EncoderConfig encoder_config;
  // Clamp to even (H.264). EvenCaptureDimension is the SAME helper the WGC
  // backend applies to every captured frame, so the encoder input size always
  // equals the surface it is handed — even for an odd-sized window (monitor
  // sizes are already even, so the display path is unchanged).
  encoder_config.width = EvenCaptureDimension(width);
  encoder_config.height = EvenCaptureDimension(height);
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
    return fail_start(clingfy::bridge::error::kRecordingError,
                      enc_err->message);
  }
  current_output_path_ = encoder_config.output_path;

  frame_queue_ = std::make_unique<VideoFrameQueue>(/*capacity=*/60);
  capture_backend_ = std::make_unique<WgcDisplayCaptureBackend>();
  std::optional<WgcCaptureError> wgc_err =
      is_window_mode
          ? capture_backend_->StartForWindow(*window_target, *d3d_device_,
                                             *frame_queue_)
          : capture_backend_->Start(*monitor, *d3d_device_, *frame_queue_);
  if (wgc_err) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return fail_start(clingfy::bridge::error::kRecordingError,
                      wgc_err->message);
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
    {
      char buf[512];
      std::snprintf(buf, sizeof(buf),
                    "RecordingEngine: mic open attempt id=%s",
                    mic_id.empty() ? "<default>" : mic_id.c_str());
      clingfy::bridge::devices::LogDeviceProbe(buf);
    }
    auto mic_err = mic_capture_->Start(
        clingfy::audio::WasapiCaptureKind::kMicrophone, mic_id, *mic_queue_);
    if (mic_err) {
      char buf[640];
      std::snprintf(buf, sizeof(buf),
                    "RecordingEngine: mic open FAILED hr=0x%08lX msg=%s",
                    static_cast<unsigned long>(mic_err->hr),
                    mic_err->message.c_str());
      clingfy::bridge::devices::LogDeviceProbe(buf);
      mic_capture_.reset();
      mic_queue_.reset();
    } else {
      clingfy::bridge::devices::LogDeviceProbe(
          "RecordingEngine: mic open OK");
    }
  }
  if (want_loopback) {
    loopback_queue_ =
        std::make_unique<clingfy::audio::AudioPacketQueue>();
    loopback_capture_ =
        std::make_unique<clingfy::audio::WasapiAudioCapture>();
    auto loopback_err = loopback_capture_->Start(
        clingfy::audio::WasapiCaptureKind::kSystemLoopback, "",
        *loopback_queue_);
    if (loopback_err) {
      char buf[640];
      std::snprintf(buf, sizeof(buf),
                    "RecordingEngine: loopback open FAILED hr=0x%08lX msg=%s",
                    static_cast<unsigned long>(loopback_err->hr),
                    loopback_err->message.c_str());
      clingfy::bridge::devices::LogDeviceProbe(buf);
      loopback_capture_.reset();
      loopback_queue_.reset();
    } else {
      clingfy::bridge::devices::LogDeviceProbe(
          "RecordingEngine: loopback open OK");
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
  audio_write_errors_.store(0);
  audio_write_logged_first_error_.store(false);
  if (mic_capture_ != nullptr || loopback_capture_ != nullptr) {
    audio_mixer_stopped_.store(false);
    audio_mixer_thread_ = std::thread([this] {
      clingfy::bridge::devices::LogDeviceProbe(
          "RecordingEngine: audio mixer thread start");
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
          if (auto write_err = encoder_->WriteAudioPacket(mixed)) {
            audio_write_errors_.fetch_add(1, std::memory_order_relaxed);
            bool expected = false;
            if (audio_write_logged_first_error_.compare_exchange_strong(
                    expected, true)) {
              char buf[640];
              std::snprintf(buf, sizeof(buf),
                            "RecordingEngine: WriteAudioPacket FAILED "
                            "(first error) hr=0x%08lX msg=%s",
                            static_cast<unsigned long>(write_err->hr),
                            write_err->message.c_str());
              clingfy::bridge::devices::LogDeviceProbe(buf);
            }
          }
        }
      }
      clingfy::bridge::devices::LogDeviceProbe(
          "RecordingEngine: audio mixer thread exit");
    });
  }

  clock_.MarkStart();

  if (!session_.MarkStarted()) {
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return fail_start(clingfy::bridge::error::kInvalidRecordingState,
                      "Engine refused to enter Recording state.");
  }

  // Lifecycle event: the recording is officially live. Phase 3E onward
  // the Flutter UI transitions to its `recording` phase on this event
  // and only then enables the stop button.
  clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingStarted(
      request.session_id);
  return std::nullopt;
}

std::optional<RecordingError> RecordingEngine::Pause(
    const std::string& session_id) {
  std::lock_guard<std::mutex> lock(mutex_);

  if (!session_.IsActive()) {
    return RecordingError{
        clingfy::bridge::error::kNotRecording,
        "pauseRecording called with no active recording session."};
  }
  if (!session_id.empty() && !session_.session_id().empty() &&
      session_id != session_.session_id()) {
    return RecordingError{
        clingfy::bridge::error::kInvalidRecordingState,
        "pauseRecording sessionId does not match the active session."};
  }
  // Idempotent: already-paused returns success without touching the
  // captures or the clock.
  if (session_.IsPausedOrPausing()) {
    return std::nullopt;
  }
  if (session_.state() != RecordingState::kRecording) {
    return RecordingError{
        clingfy::bridge::error::kInvalidRecordingState,
        "Cannot pause a session that is mid-start or mid-stop."};
  }

  if (!session_.BeginPause()) {
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Pausing state."};
  }
  // Order: clock first (so subsequent timestamps reflect the pause),
  // then WGC (to stop pushing frames), then WASAPI (to stop the
  // upstream audio client). Reverse on resume.
  clock_.Pause();
  if (capture_backend_) {
    capture_backend_->Pause();
  }
  if (mic_capture_) {
    mic_capture_->Pause();
  }
  if (loopback_capture_) {
    loopback_capture_->Pause();
  }
  if (!session_.MarkPaused()) {
    session_.MarkFailed();
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Paused state."};
  }

  clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingPaused(
      std::string(session_.session_id()));
  return std::nullopt;
}

std::optional<RecordingError> RecordingEngine::Resume(
    const std::string& session_id) {
  std::lock_guard<std::mutex> lock(mutex_);

  if (!session_.IsActive()) {
    return RecordingError{
        clingfy::bridge::error::kNotRecording,
        "resumeRecording called with no active recording session."};
  }
  if (!session_id.empty() && !session_.session_id().empty() &&
      session_id != session_.session_id()) {
    return RecordingError{
        clingfy::bridge::error::kInvalidRecordingState,
        "resumeRecording sessionId does not match the active session."};
  }
  // Idempotent: already-recording returns success.
  if (session_.state() == RecordingState::kRecording) {
    return std::nullopt;
  }
  if (session_.state() != RecordingState::kPaused) {
    return RecordingError{
        clingfy::bridge::error::kInvalidRecordingState,
        "Cannot resume a session that is not paused."};
  }

  if (!session_.BeginResume()) {
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Resuming state."};
  }
  // Reverse pause order: WASAPI first, then WGC, then clock — the
  // capture threads need to be live before the clock starts producing
  // new sample timestamps so we don't drop a frame at the seam.
  if (loopback_capture_) {
    loopback_capture_->Resume();
  }
  if (mic_capture_) {
    mic_capture_->Resume();
  }
  if (capture_backend_) {
    capture_backend_->Resume();
  }
  clock_.Resume();
  if (!session_.MarkResumed()) {
    session_.MarkFailed();
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Recording state."};
  }

  clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingResumed(
      std::string(session_.session_id()));
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
    // Mismatched session id — do NOT emit `recordingFailed` here:
    // the existing session is still legitimately recording, and
    // surfacing a failure event would race with the eventual success
    // event for the *real* session id. Mirrors macOS.
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

  // Snapshot diagnostics + the active session id BEFORE TeardownPipeline
  // / MarkStopped clear them — the project writer needs the values
  // post-teardown, and `recordingFinalized` carries the original
  // session id.
  const std::string active_session_id(session_.session_id());
  ProjectWriterInput project_input;
  project_input.session_id = active_session_id;
  project_input.source_mp4_path = current_output_path_;
  project_input.target_type = current_target_type_;
  project_input.window_id = current_window_id_;
  if (capture_backend_) {
    const auto stats = capture_backend_->Stats();
    project_input.width = stats.frame_width;
    project_input.height = stats.frame_height;
    project_input.frames_received = stats.frames_received;
  }
  if (frame_queue_) {
    project_input.frames_dropped = frame_queue_->dropped_frame_count();
  }
  if (encoder_) {
    project_input.audio_samples_written =
        encoder_->audio_samples_written_count();
  }
  if (mic_capture_) {
    project_input.mic_active = mic_capture_->running();
  }
  if (loopback_capture_) {
    project_input.loopback_active = loopback_capture_->running();
  }

  // We populate `fps` from the encoder's config so the meta.json
  // reflects the *configured* rate, not whatever the capture happened
  // to deliver. The encoder doesn't expose its config struct directly;
  // for Phase 3E we just store it on the engine when Start completes
  // and read it back here. Future polish: thread the value through
  // Diagnostics().
  // (Width/height/fps may be zero if no frames arrived; that's fine —
  // the meta.json still validates as JSON.)

  if (!session_.BeginStop()) {
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Cannot stop a session that has not finished "
                          "starting."};
  }

  // Audio pipeline summary log. Phase 5 follow-up to PR #122's open-time
  // logging — captures the four numbers that pinpoint which stage of the
  // pipeline lost the audio (WASAPI delivery, mixer activity, encoder
  // accept, write errors).
  {
    const auto mic_packets =
        mic_capture_ ? mic_capture_->packets_emitted() : 0ULL;
    const auto loopback_packets =
        loopback_capture_ ? loopback_capture_->packets_emitted() : 0ULL;
    const auto audio_samples_written =
        encoder_ ? encoder_->audio_samples_written_count() : 0ULL;
    const auto write_errors =
        audio_write_errors_.load(std::memory_order_relaxed);
    char buf[512];
    std::snprintf(buf, sizeof(buf),
                  "RecordingEngine: stop summary mic_packets=%llu "
                  "loopback_packets=%llu audio_samples_written=%llu "
                  "write_errors=%llu",
                  static_cast<unsigned long long>(mic_packets),
                  static_cast<unsigned long long>(loopback_packets),
                  static_cast<unsigned long long>(audio_samples_written),
                  static_cast<unsigned long long>(write_errors));
    clingfy::bridge::devices::LogDeviceProbe(buf);
  }

  TeardownPipeline();

  if (!session_.MarkStopped()) {
    session_.MarkFailed();
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize",
        clingfy::bridge::error::kInvalidRecordingState,
        "Engine refused to enter Stopped state.");
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Stopped state."};
  }
  session_.Reset();

  // Project finalize: reshape the encoder's temp MP4 into a
  // `.clingfyproj` bundle Dart can open. On failure we still consider
  // the stopRecording call successful (the file exists in %TEMP%) but
  // emit a `recordingFailed` event so the UI surfaces the issue.
  auto writer_result = WriteRecordingProject(project_input);
  if (writer_result.kind == ProjectWriterErrorKind::kNone) {
    clingfy::bridge::WorkflowEventPublisher::Instance()
        .EmitRecordingFinalized(active_session_id,
                                 writer_result.project_path);
  } else {
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize",
        clingfy::bridge::error::kRecordingError, writer_result.message);
  }
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
    out.audio_samples_written = encoder_->audio_samples_written_count();
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
  current_target_type_ = "display";
  current_window_id_.reset();
}

}  // namespace clingfy::capture
