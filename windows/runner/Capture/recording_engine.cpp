#include "Capture/recording_engine.h"

#include <windows.h>
#include <dwmapi.h>

#include <algorithm>
#include <cstdio>
#include <functional>
#include <thread>
#include <utility>

#include "Audio/audio_mixer.h"
#include "Audio/audio_packet.h"
#include "Audio/audio_packet_queue.h"
#include "Audio/wasapi_audio_capture.h"
#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/Devices/display_enumerator.h"
#include "Bridge/Devices/video_source_enumerator.h"
#include "Bridge/Devices/window_enumerator.h"
#include "Bridge/native_error_codes.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Bridge/workflow_event_publisher.h"
#include "Capture/Camera/camera_floating_overlay.h"
#include "Capture/Camera/camera_meta.h"
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
    current_source_bounds_.reset();
  } else if (is_area_mode) {
    const auto region = WindowsSelectionState::Instance().CurrentAreaRegion();
    if (!region) {
      return fail_start(
          clingfy::bridge::error::kTargetError,
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
    TeardownPipeline();
    session_.MarkFailed();
    session_.Reset();
    return fail_start(clingfy::bridge::error::kRecordingError,
                      enc_err->message);
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
          clingfy::bridge::WorkflowEventPublisher::Instance()
              .EmitRecordingWarning(
                  sid,
                  "Your camera was disconnected. Recording continues without "
                  "it.");
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
        camera_floating_ = std::make_unique<CameraFloatingOverlay>();
        if (!camera_floating_->Start(place)) {
          camera_floating_.reset();
          clingfy::bridge::devices::LogDeviceProbe(
              "RecordingEngine: floating camera overlay create failed; in-app "
              "preview only");
        }
      }
      CameraFloatingOverlay* floating = camera_floating_.get();
      cam_cfg.on_preview_frame = [floating](const std::uint8_t* bgra, int w,
                                            int h) {
        LiveCameraTexture::Instance().PublishBgra(bgra, w, h);
        if (floating != nullptr) {
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
        camera_recorder_.reset();
        if (camera_floating_) {
          camera_floating_->Stop();
          camera_floating_.reset();
        }
        clingfy::bridge::devices::LogDeviceProbe(
            "RecordingEngine: camera init failed; continuing screen-only");
      }
    } else {
      // The user wanted a camera but it is not ready — surface why in the log.
      const std::string camera_reason =
          std::string("RecordingEngine: camera overlay requested but ") +
          clingfy::permissions::CameraReadinessReason(readiness.code);
      clingfy::bridge::devices::LogDeviceProbe(camera_reason.c_str());
    }
  }

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

  if (!session_.BeginStop()) {
    // Mid-start / mid-stop — cannot cleanly finalize from here. Surface a
    // failure rather than leaving the UI stuck on a recording that is gone.
    session_.MarkFailed();
    session_.Reset();
    TeardownPipeline();
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

  auto writer_result = WriteRecordingProject(project_input);
  const bool writer_ok = writer_result.kind == ProjectWriterErrorKind::kNone;
  const bool kept = writer_ok && project_input.frames_received > 0;
  if (kept) {
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingWarning(
        active_session_id, warn_msg);
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFinalized(
        active_session_id, writer_result.project_path);
  } else if (writer_ok) {
    // The writer succeeded but nothing was captured (the target vanished before
    // a frame arrived) — the cause genuinely is the lost target.
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize", clingfy::bridge::error::kTargetError,
        fail_msg);
  } else {
    // The writer itself failed (disk / filesystem). Report it the same way Stop
    // does — a write failure is a RECORDING_ERROR, not a target error — so the
    // two finalize paths stay consistent.
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitRecordingFailed(
        active_session_id, "finalize", clingfy::bridge::error::kRecordingError,
        writer_result.message);
  }
}

void RecordingEngine::TeardownPipeline() {
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
