#include "Capture/recording_engine.h"

#include <windows.h>
#include <dwmapi.h>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>

#include "Audio/audio_mixer.h"
#include "Audio/audio_packet.h"
#include "Audio/audio_packet_queue.h"
#include "Audio/wasapi_audio_capture.h"
#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/Devices/display_enumerator.h"
#include "Bridge/Devices/video_source_enumerator.h"
#include "Bridge/Devices/window_enumerator.h"
#include "Bridge/native_error_codes.h"
#include "Bridge/native_log_publisher.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Bridge/recording_warning_codes.h"
#include "Bridge/workflow_event_publisher.h"
#include "Services/recovery_sweep.h"
#include "Capture/Camera/camera_overlay_host.h"
#include "Capture/Camera/camera_overlay_presenter.h"
#include "Capture/Camera/camera_meta.h"
#include "Capture/Camera/camera_overlay_style_store.h"
#include "Capture/Camera/camera_recorder.h"
#include "Capture/Camera/live_camera_texture.h"
#include "Capture/captured_video_frame.h"
#include "Capture/Cursor/cursor_sampler.h"
#include "Capture/recording_project_writer.h"
#include "Capture/video_frame_queue.h"
#include "Capture/wgc_display_capture_backend.h"
#include "Capture/windows_selection_state.h"
#include "Encoding/encoder_output_path.h"
#include "Encoding/mf_encoder_config.h"
#include "Encoding/mf_sink_writer_encoder.h"
#include "Graphics/d3d_device.h"
#include "Permissions/camera_readiness.h"
#include "Permissions/permission_probe.h"

namespace clingfy::capture {

namespace {

// Phase 10.4: keepalive for camera recorders whose device-open wedged inside
// Media Foundation (see CameraRecorder::open_timed_out()). Their detached
// thread may unblock at any time and touch the object, so destruction is
// never safe — park them for the process lifetime. Intentionally leaked
// (heap-allocated, never freed) so CRT static-destruction order can't race
// a worker that unwedges during exit. One leaked thread+object per
// occurrence beats an unbounded startRecording hang or a UAF.
std::vector<std::unique_ptr<CameraRecorder>>& AbandonedCameraRecorders() {
  static auto* recorders =
      new std::vector<std::unique_ptr<CameraRecorder>>();
  return *recorders;
}

// Phase 10.4: rewrite a bundle's manifest `status` to "failed" in place.
// Value-agnostic (works for "capturing" provisionals and zero-frame "ready"
// bundles). Best-effort; returns false when the manifest is unreadable or
// the status key wasn't found.
bool StampBundleFailed(const std::string& bundle_path) {
  if (bundle_path.empty()) return false;
  const std::filesystem::path manifest =
      std::filesystem::u8path(bundle_path) / "project.json";
  std::ifstream in(manifest, std::ios::binary);
  if (!in.is_open()) return false;
  std::ostringstream buffer;
  buffer << in.rdbuf();
  in.close();
  const auto rewritten = clingfy::services::ReplaceJsonStringValue(
      buffer.str(), "status", "failed");
  if (!rewritten) return false;
  std::ofstream out(manifest, std::ios::binary | std::ios::trunc);
  if (!out.is_open()) return false;
  out.write(rewritten->data(),
            static_cast<std::streamsize>(rewritten->size()));
  return out.good();
}

// Free bytes on the volume containing `directory`; empty when the query
// fails (the gate fails OPEN in that case).
std::optional<std::uint64_t> FreeBytesForDirectory(
    const std::filesystem::path& directory) {
  if (directory.empty()) return std::nullopt;
  ULARGE_INTEGER available{};
  if (::GetDiskFreeSpaceExW(directory.c_str(), &available, nullptr,
                            nullptr) == 0) {
    return std::nullopt;
  }
  return static_cast<std::uint64_t>(available.QuadPart);
}

}  // namespace

StartDiskGate EvaluateStartDiskGate(std::optional<std::uint64_t> free_bytes,
                                    bool allow_low_storage_bypass) {
  if (!free_bytes.has_value()) {
    return StartDiskGate::kOk;  // never block on a failed QUERY
  }
  if (*free_bytes < kStartDiskHardFloorBytes) {
    return StartDiskGate::kBlocked;  // bypass does not apply below the floor
  }
  if (*free_bytes < kStartDiskSoftFloorBytes && !allow_low_storage_bypass) {
    return StartDiskGate::kBlocked;
  }
  return StartDiskGate::kOk;
}

RecordingEngine& RecordingEngine::Instance() {
  static RecordingEngine engine;
  return engine;
}

bool RecordingEngine::IsSessionActive() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return session_.IsActive();
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
    // Phase 10.4: hard start failures used to be invisible to the JSONL
    // logs and Sentry (the Dart toast was the only trace). The publisher
    // promotes native ERROR lines to Sentry events, so every refused start
    // now leaves a diagnosable trail.
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Recording", "startRecording failed code=" + code + ": " + msg);
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

  // Phase 10.4: native disk preflight (D6 — the Dart-side storage dialog is
  // advisory and silently skipped when its snapshot fetch fails; this is
  // the engine-side floor). The encoder writes to %TEMP% and the bundle
  // lands under the recordings root — gate on the tighter of the two.
  {
    std::error_code disk_ec;
    const auto temp_free =
        FreeBytesForDirectory(std::filesystem::temp_directory_path(disk_ec));
    const auto recordings_free = FreeBytesForDirectory(
        std::filesystem::u8path(ResolveDefaultRecordingsRoot()));
    std::optional<std::uint64_t> free_bytes;
    if (temp_free && recordings_free) {
      free_bytes = std::min(*temp_free, *recordings_free);
    } else if (temp_free) {
      free_bytes = temp_free;
    } else {
      free_bytes = recordings_free;
    }
    if (EvaluateStartDiskGate(free_bytes, request.allow_low_storage_bypass) ==
        StartDiskGate::kBlocked) {
      return fail_start(
          clingfy::bridge::error::kRecordingDiskFull,
          "Not enough free disk space to start recording (free: " +
              std::to_string(free_bytes.value_or(0) / (1024 * 1024)) +
              " MiB).");
    }
  }

  const DisplayTargetMode mode =
      WindowsSelectionState::Instance().TargetMode();
  // Phase 7.1 lifts the gate for window modes. macOS distinguishes "app (all
  // windows)" from "single window"; WGC captures one HWND, so both map to
  // single-HWND capture of the selected window for the MVP. Area / mouse modes
  // remain unsupported until their slices.
  const bool is_window_mode = (mode == DisplayTargetMode::kAppWindow ||
                               mode == DisplayTargetMode::kSingleAppWindow);
  const bool is_area_mode = (mode == DisplayTargetMode::kAreaRecording);
  if (mode != DisplayTargetMode::kExplicitId && !is_window_mode &&
      !is_area_mode) {
    return fail_start(
        clingfy::bridge::error::kBadMode,
        std::string("Target mode '") + TargetModeName(mode) +
            "' is not supported on Windows yet. Window and area recording are "
            "live; mouse-follow modes land in a later slice.");
  }

  // Resolve the target BEFORE any pipeline setup so a missing / stale target
  // fails cleanly. Display: an HMONITOR (nullopt selection => primary). Window:
  // the selected HWND, revalidated. Area: the selected region's monitor + a crop
  // box resolved/clamped against the monitor size.
  std::optional<HMONITOR> monitor;
  std::optional<HWND> window_target;
  std::optional<CaptureCropBox> area_crop;
  if (is_window_mode) {
    const auto window_id = WindowsSelectionState::Instance().AppWindowId();
    if (!window_id) {
      // Phase 10.4: the specific macOS-parity codes (already mapped with
      // better copy in HomeErrorMapper) instead of blanket TARGET_ERROR.
      return fail_start(
          clingfy::bridge::error::kNoWindowSelected,
          "No window selected to record. Pick a window first.");
    }
    window_target = clingfy::bridge::devices::ResolveAppWindow(window_id);
    if (!window_target) {
      return fail_start(
          clingfy::bridge::error::kWindowNotAvailable,
          "The selected window is no longer available. Pick it again.");
    }
    current_target_type_ = "window";
    current_window_id_ = window_id;
    current_source_bounds_.reset();
  } else if (is_area_mode) {
    const auto region = WindowsSelectionState::Instance().CurrentAreaRegion();
    if (!region) {
      return fail_start(
          clingfy::bridge::error::kNoAreaSelected,
          "No area selected to record. Pick an area first.");
    }
    monitor = clingfy::bridge::devices::ResolveHMonitor(region->display_id);
    if (!monitor) {
      return fail_start(
          clingfy::bridge::error::kTargetError,
          "The display for the selected area is no longer available.");
    }
    MONITORINFO area_info{};
    area_info.cbSize = sizeof(area_info);
    std::uint32_t mon_w = 0;
    std::uint32_t mon_h = 0;
    if (::GetMonitorInfoW(*monitor, &area_info) != 0) {
      mon_w = static_cast<std::uint32_t>(area_info.rcMonitor.right -
                                         area_info.rcMonitor.left);
      mon_h = static_cast<std::uint32_t>(area_info.rcMonitor.bottom -
                                         area_info.rcMonitor.top);
    }
    const CaptureCropBox crop = clingfy::capture::ResolveCropBox(
        mon_w, mon_h, region->x, region->y, region->width, region->height);
    if (crop.width == 0 || crop.height == 0) {
      return fail_start(
          clingfy::bridge::error::kTargetError,
          "The selected area is empty or off-screen. Pick it again.");
    }
    area_crop = crop;
    current_target_type_ = "area";
    current_window_id_.reset();
    current_source_bounds_ = SourceBounds{
        static_cast<std::int32_t>(crop.x), static_cast<std::int32_t>(crop.y),
        static_cast<std::int32_t>(crop.width),
        static_cast<std::int32_t>(crop.height)};
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
    current_source_bounds_.reset();
  }

  if (!session_.BeginStart(request.session_id)) {
    return fail_start(clingfy::bridge::error::kInvalidRecordingState,
                      "Engine refused to enter Starting state.");
  }

  d3d_device_ = std::make_unique<clingfy::graphics::D3DDevice>();
  if (auto d3d_err = d3d_device_->Create()) {
    TeardownPipeline(/*finalize_encoder=*/false);
    CleanupFailedStartArtifacts(request.session_id);
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
      TeardownPipeline(/*finalize_encoder=*/false);
      CleanupFailedStartArtifacts(request.session_id);
      session_.MarkFailed();
      session_.Reset();
      return fail_start(
          clingfy::bridge::error::kWindowNotAvailable,
          "Could not measure the selected window for capture. Pick it "
          "again.");
    }
    width = window_size->width;
    height = window_size->height;
  } else if (is_area_mode) {
    // The crop box is already clamped + even-aligned; the backend crops every
    // frame to exactly this size, so the encoder must match it.
    width = area_crop->width;
    height = area_crop->height;
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
    TeardownPipeline(/*finalize_encoder=*/false);
    CleanupFailedStartArtifacts(request.session_id);
    session_.MarkFailed();
    session_.Reset();
    char hr_buf[32];
    std::snprintf(hr_buf, sizeof(hr_buf), " (hr=0x%08lX)",
                  static_cast<unsigned long>(enc_err->hr));
    return fail_start(clingfy::bridge::error::kRecordingError,
                      enc_err->message + hr_buf);
  }
  current_output_path_ = encoder_config.output_path;

  frame_queue_ = std::make_unique<VideoFrameQueue>(/*capacity=*/60);
  capture_backend_ = std::make_unique<WgcDisplayCaptureBackend>();
  // Phase 7.4: target-loss. WGC raises GraphicsCaptureItem.Closed when the
  // captured window closes or the captured monitor is unplugged. It fires on a
  // WinRT thread, so we marshal onto the platform thread (where Start / Stop run)
  // before the stop+finalize — `HandleTargetLost` re-validates the session under
  // the engine mutex, so a stale or duplicate post is a no-op.
  //
  // `PlatformThreadDispatcher::Post` may run the task INLINE on the calling
  // (WinRT) thread — when the dispatcher is uninitialized OR when PostMessage
  // fails on a saturated queue. That is tolerated here: the backend's Closed
  // handler does NOT revoke its own token (the guard-disarm in
  // WgcDisplayCaptureBackend::Stop replaces the revoke), so running HandleTargetLost
  // inline inside the Closed handler can no longer self-join. The engine mutex it
  // takes may briefly contend with a racing user Stop, but never deadlocks.
  {
    const std::string sid = request.session_id;
    capture_backend_->SetTargetLostCallback([sid]() {
      clingfy::bridge::PlatformThreadDispatcher::Instance().Post([sid]() {
        RecordingEngine::Instance().HandleTargetLost(sid);
      });
    });
  }
  std::optional<WgcCaptureError> wgc_err;
  if (is_window_mode) {
    wgc_err = capture_backend_->StartForWindow(*window_target, *d3d_device_,
                                               *frame_queue_);
  } else if (is_area_mode) {
    wgc_err = capture_backend_->StartForArea(*monitor, *area_crop, *d3d_device_,
                                             *frame_queue_);
  } else {
    wgc_err = capture_backend_->Start(*monitor, *d3d_device_, *frame_queue_);
  }
  if (wgc_err) {
    TeardownPipeline(/*finalize_encoder=*/false);
    CleanupFailedStartArtifacts(request.session_id);
    session_.MarkFailed();
    session_.Reset();
    char hr_buf[32];
    std::snprintf(hr_buf, sizeof(hr_buf), " (hr=0x%08lX)",
                  static_cast<unsigned long>(wgc_err->hr));
    return fail_start(clingfy::bridge::error::kRecordingError,
                      wgc_err->message + hr_buf);
  }

  // Audio captures: each is best-effort. If mic open fails we log and
  // continue with loopback only; if loopback fails we continue with mic
  // only. Both failing isn't a hard error either — the recording still
  // produces a video-only MP4, which is the macOS engine's behavior on
  // a host with no audio devices.
  //
  // Phase 10.1 — zero silent degradation: every best-effort fallback below
  // ALSO queues a user-visible recordingWarning (delivered after
  // recordingStarted so the workflow ordering stays sane) and forwards an
  // ERROR line over the native→Dart log bridge so the degradation reaches
  // the JSONL logs and Sentry. Behavior is otherwise unchanged.
  // (message, code) pairs — the code lets Dart localize + attach the
  // right settings action (see workflow_event_publisher.h).
  std::vector<std::pair<std::string, std::string>> start_warnings;
  // Mid-record WASAPI failure (device unplug → AUDCLNT_E_DEVICE_INVALIDATED)
  // used to be a fully silent forever-spin. The callback fires once, from
  // the capture thread; both the warning publisher and the log publisher
  // marshal internally, and the lambda captures only the session id.
  const std::string warn_sid = request.session_id;
  const auto on_audio_capture_error = [warn_sid](
                                          clingfy::audio::WasapiCaptureKind k,
                                          HRESULT hr) {
    const bool is_mic = k == clingfy::audio::WasapiCaptureKind::kMicrophone;
    {
      char buf[256];
      std::snprintf(buf, sizeof(buf),
                    "RecordingEngine: %s capture FAILED mid-record "
                    "hr=0x%08lX",
                    is_mic ? "mic" : "loopback",
                    static_cast<unsigned long>(hr));
      clingfy::bridge::devices::LogDeviceProbe(buf);
      clingfy::bridge::NativeLogPublisher::Instance().Error("Recording", buf);
    }
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingWarning(
        warn_sid,
        is_mic ? "Your microphone was disconnected. Recording continues "
                 "without it."
               : "System audio stopped. Recording continues without it.",
        is_mic ? clingfy::bridge::warning::kMicDisconnected
               : clingfy::bridge::warning::kSystemAudioStopped);
  };
  if (want_mic) {
    mic_queue_ = std::make_unique<clingfy::audio::AudioPacketQueue>();
    mic_capture_ =
        std::make_unique<clingfy::audio::WasapiAudioCapture>();
    mic_capture_->SetOnCaptureError(on_audio_capture_error);
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
      clingfy::bridge::NativeLogPublisher::Instance().Error("Recording", buf);
      start_warnings.emplace_back(
          "Your microphone couldn't be started. Recording continues without "
          "microphone audio.",
          clingfy::bridge::warning::kMicOpenFailed);
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
    loopback_capture_->SetOnCaptureError(on_audio_capture_error);
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
      clingfy::bridge::NativeLogPublisher::Instance().Error("Recording", buf);
      start_warnings.emplace_back(
          "System audio couldn't be captured. Recording continues without "
          "system audio.",
          clingfy::bridge::warning::kSystemAudioOpenFailed);
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
  video_write_logged_first_error_.store(false);
  encoder_thread_ = std::thread([this, warn_sid] {
    auto* queue = frame_queue_.get();
    auto* encoder = encoder_.get();
    if (queue == nullptr || encoder == nullptr) {
      return;
    }
    while (auto frame = queue->Pop()) {
      if (encoder_stopped_.load()) {
        break;
      }
      // Phase 10.1: an encoder write failure mid-record used to be
      // discarded — a dead encoder kept "recording" with no signal until
      // Stop. Surface the FIRST failure as a warning; the drain loop keeps
      // its existing behavior (no early abort) so this stays
      // surfacing-only.
      if (auto write_err = encoder->WriteVideoFrame(*frame)) {
        bool expected = false;
        if (video_write_logged_first_error_.compare_exchange_strong(expected,
                                                                    true)) {
          char buf[640];
          std::snprintf(buf, sizeof(buf),
                        "RecordingEngine: WriteVideoFrame FAILED (first "
                        "error) hr=0x%08lX msg=%s",
                        static_cast<unsigned long>(write_err->hr),
                        write_err->message.c_str());
          clingfy::bridge::devices::LogDeviceProbe(buf);
          clingfy::bridge::NativeLogPublisher::Instance().Error("Recording",
                                                                buf);
          clingfy::bridge::WorkflowEventPublisher::Instance()
              .EmitRecordingWarning(
                  warn_sid,
                  "Recording ran into an encoder problem. The recording may "
                  "be incomplete.",
                  clingfy::bridge::warning::kEncoderVideoError);
        }
      }
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
    audio_mixer_thread_ = std::thread([this, warn_sid] {
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
              // Phase 10.1: the file-only breadcrumb above never reached
              // the user or Sentry — surface the first audio write error.
              clingfy::bridge::NativeLogPublisher::Instance().Error(
                  "Recording", buf);
              clingfy::bridge::WorkflowEventPublisher::Instance()
                  .EmitRecordingWarning(
                      warn_sid,
                      "Recording ran into an audio encoding problem. The "
                      "recording's audio may be incomplete.",
                      clingfy::bridge::warning::kEncoderAudioError);
            }
          }
        }
      }
      clingfy::bridge::devices::LogDeviceProbe(
          "RecordingEngine: audio mixer thread exit");
    });
  }

  clock_.MarkStart();

  // Phase 8.1: start the cursor sidecar sampler. We only flip the WGC cursor
  // capture OFF after the sampler is confirmed running, so a sampler failure
  // falls back to the Phase 7 burned-in cursor (D1). The sampler maps the cursor
  // into capture-local px per target mode; window mode recomputes the origin each
  // tick from the DWM extended frame bounds (the window may move).
  current_cursor_sidecar_path_.clear();
  current_cursor_enabled_ = false;
  {
    CursorSampler::Config cfg;
    cfg.sidecar_path =
        clingfy::encoding::ResolveTempCursorSidecarPath(request.session_id);
    cfg.target_type = current_target_type_;
    cfg.width = static_cast<std::int32_t>(encoder_config.width);
    cfg.height = static_cast<std::int32_t>(encoder_config.height);
    cfg.sample_rate_hz = 60;
    cfg.heartbeat_ms = 1000;
    cfg.enable_click_hook = true;

    CursorSampler::OriginFn origin_fn;
    if (is_window_mode) {
      const HWND hwnd = *window_target;
      RECT frame{};
      if (::DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &frame,
                                  sizeof(frame)) == S_OK ||
          ::GetWindowRect(hwnd, &frame) != 0) {
        cfg.header_origin_x = frame.left;
        cfg.header_origin_y = frame.top;
      }
      origin_fn = [hwnd](std::int32_t& x, std::int32_t& y) {
        RECT r{};
        if (::DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &r,
                                    sizeof(r)) == S_OK ||
            ::GetWindowRect(hwnd, &r) != 0) {
          x = r.left;
          y = r.top;
        }
      };
    } else {
      std::int32_t mon_left = 0;
      std::int32_t mon_top = 0;
      if (monitor.has_value()) {
        MONITORINFO mi{};
        mi.cbSize = sizeof(mi);
        if (::GetMonitorInfoW(*monitor, &mi) != 0) {
          mon_left = mi.rcMonitor.left;
          mon_top = mi.rcMonitor.top;
        }
      }
      if (is_area_mode && area_crop.has_value()) {
        cfg.header_origin_x =
            mon_left + static_cast<std::int32_t>(area_crop->x);
        cfg.header_origin_y =
            mon_top + static_cast<std::int32_t>(area_crop->y);
      } else {
        cfg.header_origin_x = mon_left;
        cfg.header_origin_y = mon_top;
      }
      const std::int32_t origin_x = cfg.header_origin_x;
      const std::int32_t origin_y = cfg.header_origin_y;
      origin_fn = [origin_x, origin_y](std::int32_t& x, std::int32_t& y) {
        x = origin_x;
        y = origin_y;
      };
    }

    auto probe = []() -> CursorSampler::Probe {
      CURSORINFO ci{};
      ci.cbSize = sizeof(ci);
      if (::GetCursorInfo(&ci) != 0) {
        return CursorSampler::Probe{static_cast<std::int32_t>(ci.ptScreenPos.x),
                                    static_cast<std::int32_t>(ci.ptScreenPos.y),
                                    (ci.flags & CURSOR_SHOWING) != 0};
      }
      return CursorSampler::Probe{0, 0, false};
    };

    cursor_sampler_ = std::make_unique<CursorSampler>();
    if (cursor_sampler_->Start(cfg, std::move(probe), std::move(origin_fn))) {
      // Sidecar is live → strip the cursor from the captured video.
      capture_backend_->SetCursorCaptureEnabled(false);
      current_cursor_sidecar_path_ = cfg.sidecar_path;
      current_cursor_enabled_ = true;
    } else {
      // Fallback: keep the Phase 7 burned-in cursor; no sidecar.
      cursor_sampler_.reset();
      clingfy::bridge::devices::LogDeviceProbe(
          "RecordingEngine: cursor sidecar init failed; keeping cursor-on "
          "fallback");
      // Phase 10.4: surface the degradation to JSONL/Sentry (no toast — the
      // burned-in fallback still records the cursor; smart zoom and cursor
      // effects are what silently degrade).
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Recording",
          "cursor sidecar init failed; falling back to burned-in cursor "
          "(export cursor/zoom effects unavailable for this recording)");
    }
  }

  // Phase 9.2: start the camera recorder when the user wants a camera overlay
  // AND a usable camera is selected + permitted. Everything is soft-fail — any
  // problem (overlay disabled, no/unavailable device, permission denied, open
  // failure) leaves the screen recording running camera-less. The camera is an
  // independent producer (its own thread + sink writer), so it cannot affect the
  // screen pipeline.
  current_camera_raw_path_.clear();
  current_camera_device_id_.clear();
  current_camera_enabled_ = false;
  current_camera_meta_json_.clear();
  // Unconditional gate log: the camera decision was previously silent on the
  // skip + happy paths, so an "overlay enabled but no bubble" report could not
  // be diagnosed from the log. This shows exactly why the camera block runs or
  // is skipped (the disableCameraOverlay flag Dart sends + whether a device is
  // selected natively).
  {
    char gate[160];
    std::snprintf(
        gate, sizeof(gate),
        "RecordingEngine: camera gate disableOverlay=%d deviceSelected=%d",
        request.disable_camera_overlay ? 1 : 0,
        WindowsSelectionState::Instance().VideoSourceId().has_value() ? 1 : 0);
    clingfy::bridge::devices::LogDeviceProbe(gate);
  }
  // Only probe permission + enumerate devices when the user actually wants a
  // camera — a screen-only recording (the default) must not pay for camera
  // enumeration or briefly open a camera device.
  if (!request.disable_camera_overlay) {
    const clingfy::permissions::CameraPermission cam_permission =
        clingfy::permissions::ProbeCameraPermission();
    const std::optional<std::string> selected =
        WindowsSelectionState::Instance().VideoSourceId();
    std::vector<std::string> available_ids;
    for (const auto& rec : clingfy::bridge::devices::EnumerateVideoInputs()) {
      available_ids.push_back(rec.id);
    }
    const clingfy::permissions::CameraReadinessResult readiness =
        clingfy::permissions::ResolveCameraReadiness(cam_permission, selected,
                                                     available_ids);
    if (clingfy::permissions::ShouldAttemptCameraCapture(
            request.disable_camera_overlay, readiness)) {
      const std::string sid = request.session_id;
      CameraRecorder::Config cam_cfg;
      cam_cfg.device_symlink = *selected;
      cam_cfg.temp_raw_path =
          clingfy::encoding::ResolveTempCameraRawPath(request.session_id);
      cam_cfg.target_fps = 30;
      // Anchor the camera's first-frame offset to the engine timeline: the
      // engine clock was marked above, so its elapsed-now is the screen-relative
      // time at which the camera begins. The camera adds its own warm-up +
      // first-frame latency on top.
      cam_cfg.base_offset_hns = clock_.ElapsedHns();
      // Device loss mid-record: post a non-fatal warning onto the platform
      // thread (the proven-safe marshal — captures only the session id + the
      // singleton publisher, never `this`, so it cannot outlive-dangle). The
      // recorder finalizes the partial raw.mov itself; the screen keeps going.
      cam_cfg.on_device_lost = [sid]() {
        clingfy::bridge::PlatformThreadDispatcher::Instance().Post([sid]() {
          // Phase 10.4: device loss previously emitted only the toast — no
          // log line, invisible to JSONL/Sentry.
          clingfy::bridge::NativeLogPublisher::Instance().Error(
              "Recording",
              "camera device lost mid-recording (session " + sid +
                  "); camera capture stopped, screen recording continues");
          clingfy::bridge::WorkflowEventPublisher::Instance()
              .EmitRecordingWarning(
                  sid,
                  "Your camera was disconnected. Recording continues without "
                  "it.",
                  clingfy::bridge::warning::kCameraDisconnected);
        });
      };

      // Phase 9.3.2: create the floating bubble (hidden + capture-excluded) and
      // feed BOTH it and the app-lifetime in-app texture, so the user can switch
      // preview modes instantly. The floating bubble is Shown only when Dart
      // selects floating mode AND exclusion succeeded (SetCameraPreviewFloating);
      // it is NEVER burned into screen.mov (WDA_EXCLUDEFROMCAPTURE), and neither
      // is the in-app texture (it lives in the app window). previewBurnedIn stays
      // false in both modes.
      {
        RECT work{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
                  ::GetSystemMetrics(SM_CYSCREEN)};
        ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        if (monitor.has_value()) {
          MONITORINFO mi{};
          mi.cbSize = sizeof(mi);
          if (::GetMonitorInfoW(*monitor, &mi) != 0) {
            work = mi.rcWork;
          }
        }
        const int work_w = work.right - work.left;
        const int work_h = work.bottom - work.top;
        FloatingPlacement place;
        place.width = std::max(160, work_w * 22 / 100);
        place.height = place.width * 9 / 16;
        const int margin = std::max(8, work_w * 3 / 100);
        place.x = work.left + std::max(0, work_w - place.width - margin);
        place.y = work.top + std::max(0, work_h - place.height - margin);
        place.rounded = true;
        // Wrap the factory ladder in the fallback host so a DComp presenter
        // that parks on persistent device loss is swapped for the GDI bubble
        // mid-recording (P4c-c3), transparently to the rest of the engine.
        auto host = std::make_shared<CameraOverlayHost>();
        camera_floating_ = host->Start(place) ? host : nullptr;
        if (camera_floating_ == nullptr) {
          clingfy::bridge::devices::LogDeviceProbe(
              "RecordingEngine: floating camera overlay create failed; in-app "
              "preview only");
        }
      }
      // Phase 10.4: weak capture (was a raw pointer). An ABANDONED camera
      // recorder (open timeout) keeps a detached thread that may deliver
      // frames long after the engine tears the overlay down; the weak_ptr
      // makes that a no-op instead of a use-after-free.
      std::weak_ptr<ICameraOverlayPresenter> floating_weak = camera_floating_;
      cam_cfg.on_preview_frame = [floating_weak](const std::uint8_t* bgra,
                                                 int w, int h) {
        LiveCameraTexture::Instance().PublishBgra(bgra, w, h);
        if (auto floating = floating_weak.lock()) {
          floating->PublishBgra(bgra, w, h);
        }
      };

      camera_recorder_ = std::make_unique<CameraRecorder>();
      if (camera_recorder_->Start(cam_cfg)) {
        current_camera_raw_path_ = cam_cfg.temp_raw_path;
        current_camera_device_id_ = *selected;
        current_camera_enabled_ = true;  // intent; finalized in teardown.
        clingfy::bridge::devices::LogDeviceProbe(
            "RecordingEngine: camera capture + preview started (floating "
            "available + in-app texture)");
      } else {
        if (camera_recorder_->open_timed_out()) {
          // Phase 10.4: the open wedged inside Media Foundation (#148
          // pathology class). The recorder cannot be joined or destroyed —
          // park it for the process lifetime and continue screen-only.
          // Its stranded temp file is removed by the next launch's
          // recovery sweep.
          clingfy::bridge::NativeLogPublisher::Instance().Error(
              "Recording",
              "camera device open timed out at recording start; camera "
              "abandoned, continuing screen-only");
          AbandonedCameraRecorders().push_back(std::move(camera_recorder_));
        } else {
          clingfy::bridge::NativeLogPublisher::Instance().Error(
              "Recording",
              "camera init failed at recording start; continuing "
              "screen-only");
        }
        camera_recorder_.reset();
        if (camera_floating_) {
          camera_floating_->Stop();
          camera_floating_.reset();
        }
        clingfy::bridge::devices::LogDeviceProbe(
            "RecordingEngine: camera init failed; continuing screen-only");
        // Phase 10.1: the user enabled the overlay and got no bubble — that
        // must never be silent.
        start_warnings.emplace_back(
            "Your camera couldn't be started. Recording continues without "
            "the camera overlay.",
            clingfy::bridge::warning::kCameraOpenFailed);
      }
    } else {
      // The user wanted a camera but it is not ready — surface why in the log.
      const std::string camera_reason =
          std::string("RecordingEngine: camera overlay requested but ") +
          clingfy::permissions::CameraReadinessReason(readiness.code);
      clingfy::bridge::devices::LogDeviceProbe(camera_reason.c_str());
      // Phase 10.1: a USER-VISIBLE warning fires only when a camera device
      // was explicitly selected — on Windows "no camera selected" IS the
      // normal screen-only flow (Dart's disableCameraOverlay flag only goes
      // true on missing permission), so warning on kNoDeviceSelected /
      // kNoDevicesAvailable would toast every default recording. With a
      // selection in place, any not-ready reason (device vanished,
      // permission revoked) is a real degradation of an explicit request.
      if (selected.has_value()) {
        clingfy::bridge::NativeLogPublisher::Instance().Warn("Recording",
                                                             camera_reason);
        start_warnings.emplace_back(
            "Your camera isn't available right now. Recording continues "
            "without the camera overlay.",
            clingfy::bridge::warning::kCameraUnavailable);
      }
    }
  }

  // Phase 10.4: provisional project bundle (status "capturing" + ownerPid),
  // macOS RecordingProjectService parity. If the process dies mid-recording
  // the next launch's recovery sweep finds this manifest, marks the project
  // failed, and tells the user — instead of leaving nothing but an
  // unplayable %TEMP% strand. Best-effort: a failure here must never refuse
  // the recording.
  {
    ProvisionalProjectInput provisional;
    provisional.session_id = request.session_id;
    const auto provisional_result = WriteProvisionalProject(provisional);
    if (provisional_result.kind == ProjectWriterErrorKind::kNone) {
      current_provisional_project_path_ = provisional_result.project_path;
    } else {
      current_provisional_project_path_.clear();
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Recording", "provisional project manifest write failed: " +
                           provisional_result.message);
    }
  }

  if (!session_.MarkStarted()) {
    TeardownPipeline(/*finalize_encoder=*/false);
    CleanupFailedStartArtifacts(request.session_id);
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
  // Phase 10.1: deliver the start-time degradation warnings AFTER
  // recordingStarted so Dart's workflow state machine sees the lifecycle
  // event first (EmitMap preserves order through the dispatcher queue).
  for (const auto& [warning_message, warning_code] : start_warnings) {
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingWarning(
        request.session_id, warning_message, warning_code);
  }
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
  if (cursor_sampler_) {
    cursor_sampler_->Pause();
  }
  if (camera_recorder_) {
    camera_recorder_->Pause();
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
  if (cursor_sampler_) {
    cursor_sampler_->Resume();
  }
  if (camera_recorder_) {
    camera_recorder_->Resume();
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
  ProjectWriterInput project_input =
      SnapshotProjectWriterInput(active_session_id);

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
  // Camera result is known only after TeardownPipeline stops the recorder, so
  // fill the camera fields here (the rest of project_input was snapshotted
  // pre-teardown when the screen pipeline was still live).
  FillCameraWriterFields(project_input);

  if (!session_.MarkStopped()) {
    session_.MarkFailed();
    MarkProvisionalProjectFailed();
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize",
        clingfy::bridge::error::kInvalidRecordingState,
        "Engine refused to enter Stopped state.");
    return RecordingError{clingfy::bridge::error::kInvalidRecordingState,
                          "Engine refused to enter Stopped state."};
  }
  session_.Reset();

  // Phase 10.4: gate the finalize on the ENCODER's outcome, not on WGC
  // delivery stats. A Finalize() failure means the MP4 has no usable moov
  // atom; zero written samples means the file is empty — either way there
  // is no recording to keep, and shipping it as `recordingFinalized` (the
  // pre-10.4 behavior) handed the user a corrupt project.
  if (!teardown_finalize_ok_ || teardown_samples_written_ == 0) {
    const std::string reason =
        !teardown_finalize_ok_
            ? "The recording file could not be finalized and is not "
              "playable."
            : "No video was captured before the recording stopped.";
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Recording",
        "stop finalize refused: " + reason + " (samples_written=" +
            std::to_string(teardown_samples_written_) + ")");
    MarkProvisionalProjectFailed();
    // The SCREEN temp is unplayable garbage at this point — clean it now.
    // Review fix: the camera raw is finalized by its OWN sink writer; when
    // it has frames it is playable footage and must survive (the
    // tombstoned bundle protects it from the next-launch sweep).
    CleanupSessionTempFiles(active_session_id,
                            /*include_camera=*/!current_camera_enabled_);
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize",
        clingfy::bridge::error::kRecordingError, reason);
    return std::nullopt;
  }

  // Project finalize: reshape the encoder's temp MP4 into a
  // `.clingfyproj` bundle Dart can open. On failure we still consider
  // the stopRecording call successful but emit a `recordingFailed` event
  // so the UI surfaces the issue.
  auto writer_result = WriteRecordingProject(project_input);
  if (writer_result.kind == ProjectWriterErrorKind::kNone) {
    current_provisional_project_path_.clear();
    // Best-effort bundling can leave cursor/camera temps behind (the screen
    // mp4 was moved by the writer). Clean the stragglers now — EXCEPT a
    // downgraded camera raw: that file is the only copy of playable camera
    // footage the writer could not move (review fix). Surface the drop
    // instead of deleting it silently.
    CleanupSessionTempFiles(active_session_id,
                            /*include_camera=*/!writer_result.camera_downgraded);
    if (writer_result.camera_downgraded) {
      clingfy::bridge::NativeLogPublisher::Instance().Error(
          "Recording",
          "camera raw could not be bundled into the project; the raw file "
          "remains in the temp folder: " +
              clingfy::encoding::ResolveTempCameraRawPath(active_session_id));
      clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingWarning(
          active_session_id,
          "Your camera footage couldn't be attached to this recording. The "
          "raw camera file was kept in the temporary folder.");
    }
    clingfy::bridge::WorkflowEventPublisher::Instance()
        .EmitRecordingFinalized(active_session_id,
                                 writer_result.project_path);
  } else {
    // Writer failure: keep the temp files (the screen mp4 is finalized and
    // playable — deleting it here would destroy the only copy; the recovery
    // sweep ages ownerless temps out later) and tombstone the bundle.
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Recording", "project writer failed at stop: " +
                         writer_result.message);
    MarkProvisionalProjectFailed();
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize",
        clingfy::bridge::error::kRecordingError, writer_result.message);
  }
  return std::nullopt;
}

ProjectWriterInput RecordingEngine::SnapshotProjectWriterInput(
    const std::string& session_id) {
  ProjectWriterInput project_input;
  project_input.session_id = session_id;
  project_input.source_mp4_path = current_output_path_;
  project_input.target_type = current_target_type_;
  project_input.window_id = current_window_id_;
  project_input.source_bounds = current_source_bounds_;
  project_input.cursor_sidecar_path = current_cursor_sidecar_path_;
  project_input.cursor_enabled = current_cursor_enabled_;
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
  return project_input;
}

void RecordingEngine::StopCameraRecorder() {
  if (!camera_recorder_) {
    return;
  }
  const CameraRecorder::Result result = camera_recorder_->Stop();
  camera_recorder_.reset();
  // Final outcome: a camera is bundled only if it actually produced frames. A
  // camera that started but delivered nothing (instant device loss) leaves no
  // usable clip, so the manifest omits the camera block.
  current_camera_enabled_ = result.frames_written > 0;
  if (current_camera_enabled_) {
    CameraMetaFields meta;
    meta.recording_id = std::string(session_.session_id());
    meta.device_id = result.device_id.empty() ? current_camera_device_id_
                                              : result.device_id;
    meta.width = result.width;
    meta.height = result.height;
    meta.fps = result.fps;
    meta.start_offset_ms = result.start_offset_ms;
    meta.frames_written = result.frames_written;
    meta.mirrored_raw = false;
    meta.device_lost = result.device_lost;
    // Phase 9.3.1: the live preview is a Flutter texture, never burned into
    // screen.mov — so the camera is NOT already in the screen video, and the
    // Phase 9.4 export should composite it from camera/raw.mov.
    meta.preview_burned_in = false;
    current_camera_meta_json_ = BuildCameraMetaJson(meta);
  } else {
    current_camera_meta_json_.clear();
  }
}

void RecordingEngine::FillCameraWriterFields(ProjectWriterInput& input) const {
  input.camera_enabled = current_camera_enabled_;
  input.camera_raw_path = current_camera_raw_path_;
  input.camera_meta_json = current_camera_meta_json_;

  // editorSeed (screen.meta.json) — capture the recording-time camera overlay
  // styling so post-processing reopens camera-on with the user's settings
  // (macOS parity via RecordingMetadata.EditorSeed). The overlay style lives in
  // the process-wide CameraOverlayStyleStore — the SAME source the live preview
  // and the export bake read — and ResolveOverlayBubbleStyle applies the exact
  // same border/chroma gating + clamps, so the seed matches what was on screen.
  const ResolvedBubbleStyle resolved =
      ResolveOverlayBubbleStyle(CameraOverlayStyleStore::Instance().Snapshot());
  CameraEditorSeed seed;
  seed.visible = current_camera_enabled_;  // a camera actually produced frames
  // Overlay position/size are not tracked natively yet: a visible camera lands
  // in the bottom-right preset (the common default) which the user can
  // reposition in the editor; size stays at the .hidden baseline.
  seed.layout_preset =
      current_camera_enabled_ ? "overlayBottomRight" : "hidden";
  seed.shape = resolved.shape;
  seed.corner_radius = resolved.corner_radius;
  seed.content_mode = resolved.content_mode;
  seed.opacity = resolved.style.opacity;
  seed.mirror = resolved.style.mirror;
  seed.border_width = resolved.style.border_width;
  if (resolved.style.has_border_color) {
    seed.border_color_argb = resolved.style.border_argb;
  }
  seed.shadow_preset = resolved.style.shadow_preset;
  seed.chroma_key_enabled = resolved.style.chroma_enabled;
  seed.chroma_key_strength = resolved.style.chroma_strength;
  if (resolved.style.chroma_enabled) {
    seed.chroma_key_color_argb = resolved.style.chroma_argb;
  }
  input.editor_seed = seed;
}

bool RecordingEngine::SetCameraPreviewFloating(bool floating) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Show the floating bubble only when requested AND it exists AND capture-
  // exclusion succeeded — never show a non-excluded floating window (it would
  // burn the camera into screen.mov + double it at export).
  if (floating && camera_floating_ != nullptr &&
      camera_floating_->wda_excluded()) {
    camera_floating_->Show();
    return true;
  }
  if (camera_floating_ != nullptr) {
    camera_floating_->Hide();
  }
  return false;  // in-app preview (requested, or floating unavailable).
}

void RecordingEngine::HandleTargetLost(const std::string& session_id) {
  std::lock_guard<std::mutex> lock(mutex_);

  // Exactly-once. Only a live, mid-flight session can be finalized by a target
  // loss. If the user's Stop (or a prior loss) already finalized, the session is
  // back to Idle and there is nothing — and nobody — to finalize. This is the
  // race guard that prevents a double finalize / double event with Stop().
  if (!session_.IsActive()) {
    return;
  }
  // A close from a previous target can fire late (the backend revokes on Stop,
  // but a delivery already in flight slips through). Ignore it unless it names
  // the session that is actually recording right now.
  if (!session_id.empty() && !session_.session_id().empty() &&
      session_id != session_.session_id()) {
    return;
  }

  const std::string active_session_id(session_.session_id());
  // Snapshot the target kind for the user-facing message BEFORE teardown (the
  // type fields survive teardown, but read it here for clarity).
  const bool was_window = current_target_type_ == "window";
  ProjectWriterInput project_input =
      SnapshotProjectWriterInput(active_session_id);

  // Phase 10.4: target loss previously emitted events only — zero log
  // lines, invisible to JSONL/Sentry.
  clingfy::bridge::NativeLogPublisher::Instance().Warn(
      "Recording",
      std::string("capture target lost mid-recording (") +
          (was_window ? "window closed" : "display disconnected") +
          "); finalizing partial recording for session " + active_session_id);

  if (!session_.BeginStop()) {
    // Mid-start / mid-stop — cannot cleanly finalize from here. Surface a
    // failure rather than leaving the UI stuck on a recording that is gone.
    session_.MarkFailed();
    session_.Reset();
    TeardownPipeline(/*finalize_encoder=*/false);
    MarkProvisionalProjectFailed();
    CleanupSessionTempFiles(active_session_id);
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize", clingfy::bridge::error::kTargetError,
        was_window
            ? "The window you were recording closed before the recording could "
              "be finalized."
            : "The display you were recording was disconnected before the "
              "recording could be finalized.");
    return;
  }

  TeardownPipeline();
  FillCameraWriterFields(project_input);

  if (!session_.MarkStopped()) {
    session_.MarkFailed();
    session_.Reset();
    MarkProvisionalProjectFailed();
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize",
        clingfy::bridge::error::kInvalidRecordingState,
        "Engine refused to enter Stopped state after target loss.");
    return;
  }
  session_.Reset();

  // Finalize the partial recording. The user chose "keep what I recorded": if a
  // playable project comes out (at least one frame AND the writer succeeded),
  // emit a friendly warning then `recordingFinalized` so the app opens the
  // partial into preview/export. If nothing usable was captured (the target
  // vanished instantly, or the writer failed), there is no recording to keep —
  // emit `recordingFailed` so the UI returns to idle with a clear reason.
  const std::string warn_msg =
      was_window
          ? "Recording stopped: the window you were recording was closed. Your "
            "recording up to that point has been saved."
          : "Recording stopped: the display you were recording was "
            "disconnected. Your recording up to that point has been saved.";
  const std::string fail_msg =
      was_window
          ? "The window you were recording closed before anything could be "
            "captured."
          : "The display you were recording was disconnected before anything "
            "could be captured.";

  // Phase 10.4: same encoder-outcome gate as Stop — a failed Finalize()
  // means the temp MP4 is unplayable, so there is nothing to bundle.
  if (!teardown_finalize_ok_) {
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Recording",
        "target-loss finalize refused: encoder finalize failed; the partial "
        "recording is not playable");
    MarkProvisionalProjectFailed();
    // Review fix: spare a camera raw with frames — it is finalized by its
    // own sink writer and playable; the tombstoned bundle protects it.
    CleanupSessionTempFiles(active_session_id,
                            /*include_camera=*/!current_camera_enabled_);
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize", clingfy::bridge::error::kRecordingError,
        "The recording file could not be finalized after the capture target "
        "was lost.");
    return;
  }

  auto writer_result = WriteRecordingProject(project_input);
  const bool writer_ok = writer_result.kind == ProjectWriterErrorKind::kNone;
  // Phase 10.4: "kept" gates on the encoder's written samples, not WGC
  // delivery stats — frames_received counts arrivals, not what made it into
  // the file.
  const bool kept = writer_ok && teardown_samples_written_ > 0;
  if (kept) {
    current_provisional_project_path_.clear();
    // Review fix: same downgraded-camera sparing as the Stop path.
    CleanupSessionTempFiles(active_session_id,
                            /*include_camera=*/!writer_result.camera_downgraded);
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingWarning(
        active_session_id, warn_msg,
        was_window
            ? clingfy::bridge::warning::kWindowClosedPartialSaved
            : clingfy::bridge::warning::kDisplayDisconnectedPartialSaved);
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFinalized(
        active_session_id, writer_result.project_path);
  } else if (writer_ok) {
    // The writer succeeded but nothing was captured (the target vanished
    // before a sample landed). The bundle it wrote claims status "ready" —
    // stamp it failed so it can't masquerade as an openable recording
    // (pre-10.4 this orphaned a zero-frame "ready" bundle forever).
    if (!StampBundleFailed(writer_result.project_path)) {
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Recording",
          "could not stamp the zero-frame bundle failed: " +
              writer_result.project_path);
    }
    current_provisional_project_path_.clear();
    CleanupSessionTempFiles(active_session_id);
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize", clingfy::bridge::error::kTargetError,
        fail_msg);
  } else {
    // The writer itself failed (disk / filesystem). Report it the same way Stop
    // does — a write failure is a RECORDING_ERROR, not a target error — so the
    // two finalize paths stay consistent. Temps are kept (the screen mp4 is
    // finalized and playable; the sweep ages them out if never recovered).
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Recording",
        "project writer failed after target loss: " + writer_result.message);
    MarkProvisionalProjectFailed();
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize", clingfy::bridge::error::kRecordingError,
        writer_result.message);
  }
}

void RecordingEngine::TeardownPipeline(bool finalize_encoder) {
  // Strict ordering: stop the capture producers first, then signal the
  // drain / mixer consumer threads via queue Close, join them, then
  // finalize the encoder so the MP4 footer is written before the
  // device that backs its DXGI manager goes away.
  // Phase 8.1: stop the cursor sampler first of all so the sidecar is flushed +
  // closed before the project writer (which runs after this on both the normal
  // Stop and target-loss finalize paths) bundles it.
  if (cursor_sampler_) {
    cursor_sampler_->Stop();
    cursor_sampler_.reset();
  }
  // Phase 9.2: stop the camera recorder + finalize its raw.mov before the
  // project writer bundles it. Recomputes the final camera-enabled flag and
  // builds the metadata from the recorder's result.
  StopCameraRecorder();
  // Phase 9.3.2: tear down the floating bubble AFTER the recorder is stopped —
  // the recorder's capture thread (the only PublishBgra caller) is joined by
  // StopCameraRecorder, so no frame can race the overlay's destruction. The
  // in-app texture is app-lifetime and just stops being fed.
  if (camera_floating_) {
    camera_floating_->Stop();
    camera_floating_.reset();
  }
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

  // Phase 10.4: capture the encoder outcome for the finalize paths' gating
  // BEFORE the encoder is destroyed. The Finalize() result used to be
  // discarded — a moov-less MP4 shipped as `recordingFinalized`.
  teardown_samples_written_ = 0;
  teardown_finalize_ok_ = true;
  if (encoder_) {
    teardown_samples_written_ = encoder_->samples_written();
    if (finalize_encoder) {
      if (auto finalize_err = encoder_->Finalize()) {
        teardown_finalize_ok_ = false;
        char buf[640];
        std::snprintf(buf, sizeof(buf),
                      "RecordingEngine: encoder Finalize FAILED hr=0x%08lX "
                      "msg=%s",
                      static_cast<unsigned long>(finalize_err->hr),
                      finalize_err->message.c_str());
        clingfy::bridge::devices::LogDeviceProbe(buf);
        clingfy::bridge::NativeLogPublisher::Instance().Error("Recording",
                                                              buf);
      }
    }
    // Failed-start paths skip Finalize: destroying the writer un-finalized
    // is a Cancel (see ~MfSinkWriterEncoder) — no zero-sample footer gets
    // written to %TEMP%.
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

void RecordingEngine::CleanupSessionTempFiles(const std::string& session_id,
                                              bool include_camera) {
  std::vector<std::string> paths = {
      clingfy::encoding::ResolveTempMp4Path(session_id),
      clingfy::encoding::ResolveTempCursorSidecarPath(session_id),
  };
  if (include_camera) {
    paths.push_back(clingfy::encoding::ResolveTempCameraRawPath(session_id));
  }
  for (const auto& path : paths) {
    if (path.empty()) continue;
    std::error_code ec;
    std::filesystem::remove(std::filesystem::u8path(path), ec);
  }
}

void RecordingEngine::CleanupFailedStartArtifacts(
    const std::string& session_id) {
  CleanupSessionTempFiles(session_id);
  if (!current_provisional_project_path_.empty()) {
    // No media has been moved into the provisional bundle on a failed start
    // — removing it entirely beats leaving a "capturing" tombstone for a
    // recording the user was already told never started.
    std::error_code ec;
    std::filesystem::remove_all(
        std::filesystem::u8path(current_provisional_project_path_), ec);
    current_provisional_project_path_.clear();
  }
}

void RecordingEngine::MarkProvisionalProjectFailed() {
  if (current_provisional_project_path_.empty()) {
    return;
  }
  if (!StampBundleFailed(current_provisional_project_path_)) {
    clingfy::bridge::NativeLogPublisher::Instance().Warn(
        "Recording", "could not stamp the provisional bundle failed: " +
                         current_provisional_project_path_);
  }
  current_provisional_project_path_.clear();
}

void RecordingEngine::StopActiveSessionForShutdown() {
  std::string active_session_id;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!session_.IsActive()) {
      return;
    }
    active_session_id = std::string(session_.session_id());
  }
  clingfy::bridge::NativeLogPublisher::Instance().Warn(
      "Recording",
      "app shutting down mid-recording; finalizing session " +
          active_session_id);
  // Stop takes the mutex itself. The tiny unlock window is fine: a racing
  // user Stop just wins, and this call becomes the idempotent no-op.
  Stop(active_session_id);
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

void RecordingEngine::FireTargetLostForTesting() {
  // Copy the installed callback out of the backend, then invoke it OUTSIDE the
  // engine lock AND outside any backend method. In tests the dispatcher is
  // uninitialized, so the callback runs HandleTargetLost inline — which re-takes
  // the engine mutex (so we must not hold it) and tears down the backend (so no
  // backend method may be on the stack). The copied std::function is
  // self-contained and stays valid after the backend is destroyed, exactly like
  // the real Closed lambda's captured copy.
  std::function<void()> cb;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (capture_backend_) {
      cb = capture_backend_->GetTargetLostCallbackForTesting();
    }
  }
  if (cb) {
    cb();
  }
}

bool RecordingEngine::cursor_enabled_for_testing() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return current_cursor_enabled_;
}

std::string RecordingEngine::cursor_sidecar_path_for_testing() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return current_cursor_sidecar_path_;
}

bool RecordingEngine::camera_recording_for_testing() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return camera_recorder_ != nullptr;
}

void RecordingEngine::ForceResetForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  TeardownPipeline();
  session_ = RecordingSessionState{};
  clock_ = RecordingClock{};
  current_output_path_.clear();
  current_target_type_ = "display";
  current_window_id_.reset();
  current_source_bounds_.reset();
  current_cursor_sidecar_path_.clear();
  current_cursor_enabled_ = false;
  current_camera_raw_path_.clear();
  current_camera_device_id_.clear();
  current_camera_enabled_ = false;
  current_camera_meta_json_.clear();
}

}  // namespace clingfy::capture
