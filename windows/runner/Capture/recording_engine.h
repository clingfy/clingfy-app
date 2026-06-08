#ifndef RUNNER_CAPTURE_RECORDING_ENGINE_H_
#define RUNNER_CAPTURE_RECORDING_ENGINE_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "Capture/recording_clock.h"
#include "Capture/recording_project_writer.h"
#include "Capture/recording_session_state.h"

namespace clingfy::audio {
class AudioPacketQueue;
class WasapiAudioCapture;
}
namespace clingfy::graphics {
class D3DDevice;
}
namespace clingfy::encoding {
class MfSinkWriterEncoder;
}

namespace clingfy::capture {
class VideoFrameQueue;
class WgcDisplayCaptureBackend;
struct WgcCaptureStats;
class CursorSampler;
class CameraRecorder;
}

// Singleton orchestrator for the Windows recording lifecycle.
//
// Phase 3A scope: the engine owns the session-state machine and the wall
// clock, accepts validated start/stop requests from the method-channel
// router, and exposes structured errors so the Dart side can map them to
// existing error UI without inventing Windows-only codes.
//
// Phase 3A does NOT yet start a capture backend, encode frames, or write
// an MP4 file — that lives in Phase 3B (`WgcDisplayCaptureBackend`), Phase
// 3C (`MfSinkWriterEncoder`), and Phase 3D (WASAPI mic / loopback). The
// engine just plumbs the lifecycle so those follow-on PRs each have a real
// hook to land code in.
//
// The engine is a Meyers singleton — the router uses function-pointer
// handlers and has no way to inject a per-instance pointer. Tests that
// need a fresh engine call `ForceReset()` between cases.
namespace clingfy::capture {

struct StartRecordingRequest {
  std::string session_id;
  std::int32_t frame_rate = 30;
  bool system_audio_enabled = false;
  bool disable_microphone = false;
  bool disable_camera_overlay = true;
  bool disable_cursor_highlight = true;
  bool allow_low_storage_bypass = false;
};

struct RecordingError {
  std::string code;
  std::string message;
};

class RecordingEngine {
 public:
  static RecordingEngine& Instance();

  RecordingEngine(const RecordingEngine&) = delete;
  RecordingEngine& operator=(const RecordingEngine&) = delete;

  // Starts a session. Returns std::nullopt on success; otherwise a
  // structured error the router forwards verbatim to Flutter. The session
  // id is what the Dart caller will quote back to `Stop`.
  std::optional<RecordingError> Start(StartRecordingRequest request);

  // Stops the active session. Idempotent: stopping when nothing is
  // recording returns success rather than an error, mirroring how the
  // macOS engine behaves when the UI fires defensive stop calls. Returns a
  // structured error only when the session id does not match.
  std::optional<RecordingError> Stop(const std::string& session_id);

  // Phase 4: pause / resume. Both are idempotent at the engine level —
  // pausing while already paused (or resuming while already recording)
  // returns success without touching the captures. A pause / resume
  // when no session is active returns kNotRecording so the Dart UI's
  // defensive double-tap surfaces a clean error instead of silently
  // succeeding.
  std::optional<RecordingError> Pause(const std::string& session_id);
  std::optional<RecordingError> Resume(const std::string& session_id);

  // Phase 7.4: the active capture target was lost mid-recording — the captured
  // window was closed or the captured monitor was unplugged (WGC raised
  // GraphicsCaptureItem.Closed). Stops the pipeline and finalizes the partial
  // recording exactly once: it re-checks the session under the lock and no-ops
  // when `session_id` is not the live session (a user Stop already won the race,
  // or a stale close from a previous target fired late). When the partial is
  // usable it emits `recordingWarning` + `recordingFinalized` so the user keeps
  // what they recorded with a friendly notice; when nothing usable was captured
  // it emits `recordingFailed` (TARGET_ERROR). Normally invoked on the platform
  // thread (the backend's Closed callback is marshaled via
  // PlatformThreadDispatcher); safe even if that marshal runs inline on the WinRT
  // thread, because the backend's target-loss teardown no longer revokes its own
  // Closed handler, so there is no self-join.
  void HandleTargetLost(const std::string& session_id);

  bool IsRecording() const;
  RecordingState state() const;
  std::string session_id() const;

  // Diagnostics snapshot — used by manual smoke-tests in Phase 3B to
  // confirm frames are arriving and by Phase 3E to surface counts on the
  // bridge. Returns zeros when no capture is in flight.
  struct CaptureDiagnostics {
    std::uint32_t frame_width = 0;
    std::uint32_t frame_height = 0;
    std::uint64_t frames_received = 0;
    std::uint64_t frames_dropped = 0;
    std::uint64_t samples_written = 0;
    // Phase 3D audio counters. mic_active / loopback_active expose
    // whether the underlying WASAPI client is alive (vs. unavailable
    // / explicitly disabled).
    bool mic_active = false;
    bool loopback_active = false;
    std::uint64_t mic_packets = 0;
    std::uint64_t loopback_packets = 0;
    std::uint64_t audio_samples_written = 0;
    std::string output_path;
  };
  CaptureDiagnostics Diagnostics() const;

  // Test seam: resets the singleton's state to Idle and clears the session
  // id. Not safe to call while a real recording is in flight (only Phase
  // 3A's skeleton path is exercised today, but later PRs that bring in
  // capture pipelines must avoid this from production code).
  void ForceResetForTesting();

  // Test seam (Phase 7.4): fire the active capture backend's target-lost
  // callback exactly as a real GraphicsCaptureItem.Closed would, exercising the
  // full Start -> SetTargetLostCallback -> PlatformThreadDispatcher::Post ->
  // HandleTargetLost wiring (which the direct HandleTargetLost tests bypass).
  // No-op when no backend is active.
  void FireTargetLostForTesting();

  // Test seams (Phase 8.1): whether the cursor sidecar sampler is active for the
  // current recording (and thus the WGC cursor was stripped), and the temp
  // sidecar path it streams to. Empty path / false when no sampler is running.
  bool cursor_enabled_for_testing() const;
  std::string cursor_sidecar_path_for_testing() const;

  // Test seam (Phase 9.2): whether the camera recorder was started for the
  // current recording (the engine's camera-capture intent). False when no
  // camera was selected, the overlay was disabled, or permission was denied.
  // (Phase 9.3.1: the live preview is an app-lifetime Flutter texture fed
  // whenever the camera records, so "camera recording" == "preview active".)
  bool camera_recording_for_testing() const;

 private:
  RecordingEngine();
  ~RecordingEngine();

  // Tears the capture pipeline down (backend → D3D device → queue) without
  // touching state-machine state. Called from Stop / failure paths so the
  // caller does not have to hand-roll the teardown order.
  void TeardownPipeline();

  // Snapshots the project-writer inputs (target metadata + capture / audio
  // diagnostics) BEFORE TeardownPipeline clears them. Shared by Stop and
  // HandleTargetLost so the two finalize paths cannot drift. Assumes the mutex
  // is held; `session_id` is the active session id to stamp on the manifest.
  ProjectWriterInput SnapshotProjectWriterInput(const std::string& session_id);

  // Phase 9.2: stop the camera recorder (if any), recompute the final
  // `current_camera_enabled_` (recorder ran AND produced frames), and build the
  // camera.meta.json string from its result. Idempotent (no-op when no recorder
  // is active). Called from TeardownPipeline so both finalize paths see the same
  // post-stop camera state. Assumes the mutex is held.
  void StopCameraRecorder();

  // Copies the post-teardown camera fields into a project-writer input. Called
  // by Stop / HandleTargetLost after TeardownPipeline (the camera result is only
  // known once the recorder is stopped, which happens inside TeardownPipeline —
  // after SnapshotProjectWriterInput has already run). Assumes the mutex held.
  void FillCameraWriterFields(ProjectWriterInput& input) const;

  mutable std::mutex mutex_;
  RecordingSessionState session_;
  RecordingClock clock_;

  // Capture pipeline (Phase 3B+). Held as unique_ptrs so the engine
  // header can stay free of D3D / WinRT / MF includes; the implementation
  // owns the full types.
  std::unique_ptr<clingfy::graphics::D3DDevice> d3d_device_;
  std::unique_ptr<VideoFrameQueue> frame_queue_;
  std::unique_ptr<WgcDisplayCaptureBackend> capture_backend_;

  // Encoder pipeline (Phase 3C). The drain thread blocks on
  // `frame_queue_->Pop()` and feeds frames to the encoder; Stop closes
  // the queue, joins the thread, then calls `encoder_->Finalize()` so
  // the MP4 footer lands before the Dart caller sees `stopRecording`
  // succeed.
  std::unique_ptr<clingfy::encoding::MfSinkWriterEncoder> encoder_;
  std::thread encoder_thread_;
  std::atomic<bool> encoder_stopped_{true};
  std::string current_output_path_;

  // Phase 7.1/7.2: the capture target the active session resolved at Start,
  // snapshot into the project manifest at Stop. "display" | "window" | "area".
  // `current_window_id_` is set only for window captures; `current_source_bounds_`
  // only for area captures (the resolved crop rect).
  std::string current_target_type_ = "display";
  std::optional<std::int64_t> current_window_id_;
  std::optional<SourceBounds> current_source_bounds_;

  // Phase 8.1: cursor sidecar. The sampler streams `cursor.jsonl` to a temp path
  // during recording; the project writer bundles it at finalize.
  // `current_cursor_enabled_` records whether the sampler started (and thus
  // whether the WGC cursor was stripped from the video) so the manifest reflects
  // it on both the normal-Stop and target-loss finalize paths.
  std::unique_ptr<CursorSampler> cursor_sampler_;
  std::string current_cursor_sidecar_path_;
  bool current_cursor_enabled_ = false;

  // Phase 9.2: camera capture. The recorder streams a raw `.mp4` to a temp path
  // during recording; the project writer bundles it into `camera/raw.mov` +
  // `camera/camera.meta.json` at finalize. `current_camera_enabled_` is the
  // INTENT at Start (the recorder started); it is recomputed in TeardownPipeline
  // to the final outcome (frames > 0) once the recorder is stopped and its
  // result is known. `current_camera_meta_json_` is built in TeardownPipeline
  // from the recorder's result. Independent of the screen pipeline — a camera
  // failure or device loss never affects the screen recording.
  std::unique_ptr<CameraRecorder> camera_recorder_;
  std::string current_camera_raw_path_;
  std::string current_camera_device_id_;
  bool current_camera_enabled_ = false;
  std::string current_camera_meta_json_;

  // Audio pipeline (Phase 3D). Two WASAPI captures (mic + loopback)
  // fill the matching packet queues; a dedicated mixer thread sums
  // both streams and forwards the mixed PCM packets into the encoder.
  // Either capture may be std::nullopt — the engine starts only the
  // half requested by `disable_microphone` / `systemAudioEnabled`.
  std::unique_ptr<clingfy::audio::WasapiAudioCapture> mic_capture_;
  std::unique_ptr<clingfy::audio::WasapiAudioCapture> loopback_capture_;
  std::unique_ptr<clingfy::audio::AudioPacketQueue> mic_queue_;
  std::unique_ptr<clingfy::audio::AudioPacketQueue> loopback_queue_;
  std::thread audio_mixer_thread_;
  std::atomic<bool> audio_mixer_stopped_{true};

  // Diagnostic counters for the audio pipeline. Phase 5 user reports of
  // "MP4 has no audio" need to distinguish three failure modes: WASAPI
  // delivered no packets, the mixer never produced non-empty packets, or
  // `MfSinkWriterEncoder::WriteAudioPacket` rejected every sample. The
  // first two are already covered by `mic_capture_->packets_emitted()` /
  // `loopback_capture_->packets_emitted()` and the encoder's
  // `audio_samples_written_count()`; this counter (plus a one-shot first-
  // error log) covers the third. All best-effort — never gates teardown.
  std::atomic<std::uint64_t> audio_write_errors_{0};
  std::atomic<bool> audio_write_logged_first_error_{false};
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_ENGINE_H_
