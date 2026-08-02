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
class AudioSidecarWriter;
}
namespace clingfy::services {
class KeepAwake;
}

namespace clingfy::capture {
class VideoFrameQueue;
class WgcDisplayCaptureBackend;
struct WgcCaptureStats;
class CursorSampler;
class CameraRecorder;
class ICameraOverlayPresenter;
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

// Phase 10.4: native disk preflight decision for recording start. Pure so
// the gate is unit-testable; the engine feeds it GetDiskFreeSpaceExW
// results. `free_bytes` empty (query failed) → allow — never block a
// recording because a disk QUERY failed. The hard floor applies even with
// the user's low-storage bypass (below it the encoder will fail within
// seconds anyway); the soft floor mirrors the Dart-side storage gate's
// critical threshold and is what `allowLowStorageBypass` bypasses.
enum class StartDiskGate { kOk, kBlocked };
inline constexpr std::uint64_t kStartDiskHardFloorBytes =
    256ull * 1024 * 1024;  // 256 MiB
inline constexpr std::uint64_t kStartDiskSoftFloorBytes =
    10ull * 1024 * 1024 * 1024;  // 10 GiB — Dart critical threshold parity
StartDiskGate EvaluateStartDiskGate(std::optional<std::uint64_t> free_bytes,
                                    bool allow_low_storage_bypass);

class RecordingEngine {
 public:
  static RecordingEngine& Instance();

  RecordingEngine(const RecordingEngine&) = delete;
  RecordingEngine& operator=(const RecordingEngine&) = delete;

  // Phase 10.3: is any recording session in flight? Used by
  // clearCachedRecordings to refuse deleting project bundles while one is
  // being written (mirrors macOS canClearCachedRecordings →
  // RECORDINGS_IN_USE).
  bool IsSessionActive() const;

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

  // Phase 9.3.2: select the live camera preview mode for the active recording.
  // `floating` true → show the topmost floating bubble IF it exists AND capture-
  // exclusion succeeded; false → hide it (the Dart in-app texture takes over).
  // Returns the RESULTING floating state: false when floating was requested but
  // is unavailable (no overlay / WDA exclusion failed), so Dart falls back to
  // the in-app preview. A no-op (returns false) when no camera is recording.
  bool SetCameraPreviewFloating(bool floating);

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

  // Phase 10.4: best-effort graceful stop for app shutdown (window close
  // mid-recording). Before this, OnDestroy killed the process with the
  // encoder unfinalized — a moov-less, unplayable strand. Synchronous (the
  // close waits for the finalize, typically <2s); a no-op when nothing is
  // recording. Events emitted during teardown may not reach Dart (the
  // channel is going away) — the point is the finalized file on disk.
  void StopActiveSessionForShutdown();

  bool IsRecording() const;
  RecordingState state() const;
  std::string session_id() const;

  // Elapsed whole seconds of the active recording, pause-aware (subtracts time
  // spent paused, matching the encoded timeline). 0 before the clock is
  // started. Thread-safe — the recording-indicator overlay thread polls this
  // once per tick to drive its native timer, so it must not push time from
  // Flutter.
  std::uint64_t ElapsedSeconds() const;

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
  //
  // Phase 10.4: `finalize_encoder` false (failed-start paths) skips
  // `Finalize()` — destroying the encoder un-finalized is a Cancel by
  // design (see ~MfSinkWriterEncoder), so a refused start no longer writes
  // a zero-sample MP4 footer to %TEMP%. The finalize outcome and the
  // encoder's video-sample count are captured into
  // `teardown_finalize_ok_` / `teardown_samples_written_` for the
  // finalize paths' kept/failed gating.
  void TeardownPipeline(bool finalize_encoder = true);

  // Phase 10.4: removes the artifacts a FAILED start leaves behind — the
  // three resolved `%TEMP%\clingfy_<sid>.*` files and the provisional
  // project bundle (no media has been moved into it at that point).
  // Best-effort; assumes the mutex is held.
  void CleanupFailedStartArtifacts(const std::string& session_id);

  // Phase 10.4: removes the session's `%TEMP%\clingfy_<sid>.*` temp files
  // (screen mp4 / cursor jsonl / camera mp4). Used after a successful
  // finalize (stragglers the writer's best-effort bundling left behind) and
  // after an unplayable-finalize failure (garbage). `include_camera` false
  // spares the camera raw (review fix): the camera finalizes its OWN sink
  // writer, so its temp is playable footage whenever it has frames — and
  // when the writer downgraded camera bundling, it is the ONLY copy.
  // Best-effort.
  void CleanupSessionTempFiles(const std::string& session_id,
                               bool include_camera = true);

  // Phase 10.4: stamps the provisional bundle (if any) `status: "failed"`
  // and clears `current_provisional_project_path_`. The tombstone is what
  // the startup recovery sweep / a future recordings list shows the user.
  void MarkProvisionalProjectFailed();

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

  // Audio separation: finalize (or cancel) the mic / system sidecar writers.
  // Called from TeardownPipeline AFTER the mixer thread joins (the writers'
  // only feeder). `keep_output` false (failed-start paths) cancels; a
  // healthy writer (no write errors, >0 samples) finalizes and sets its
  // `current_*_sidecar_ok_` flag; anything else deletes the temp. Sidecars
  // are best-effort — nothing here fails the recording. Assumes the mutex
  // is held.
  void FinalizeAudioSidecars(bool keep_output);

  // Copies the post-teardown sidecar outcome into a project-writer input.
  // Same call discipline as FillCameraWriterFields. Assumes the mutex held.
  void FillAudioSidecarWriterFields(ProjectWriterInput& input) const;

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

  // Phase 10.4: provisional bundle written at Start (status "capturing");
  // empty when the provisional write failed (best-effort). Cleared on
  // teardown. Used by CleanupFailedStartArtifacts and the failed-finalize
  // paths.
  std::string current_provisional_project_path_;
  // Phase 10.4: captured by TeardownPipeline before the encoder is
  // destroyed — the finalize paths gate "keep the recording" on the encoder
  // having actually WRITTEN samples and finalized cleanly, not on WGC
  // delivery stats (a dead-from-frame-1 encoder used to finalize as
  // success).
  std::uint64_t teardown_samples_written_ = 0;
  bool teardown_finalize_ok_ = true;

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

  // Phase 9.3.2: the floating camera bubble (topmost, capture-excluded,
  // draggable). Created hidden at camera start and fed frames alongside the
  // in-app texture; SetCameraPreviewFloating shows/hides it. Torn down after the
  // recorder (the frame producer) is stopped.
  // Phase 10.4: shared_ptr (was unique_ptr) so the camera preview hook can
  // capture a weak_ptr — an ABANDONED camera recorder's thread may deliver
  // frames long after the engine tore the overlay down, and a raw pointer
  // there would be a use-after-free.
  // Renderer P2: held through the presenter interface (GDI today, DComp in
  // P3) — see docs/decisions/windows-camera-bubble-renderer-architecture.md.
  std::shared_ptr<ICameraOverlayPresenter> camera_floating_;

  // Held for the whole session (Starting → terminal): keeps the machine out
  // of Modern Standby and the recorded display on — sleep mid-recording
  // invalidates the GPU/media stack, and a dark display records black
  // frames. Created after BeginStart, released in TeardownPipeline (every
  // end path flows through it).
  std::unique_ptr<clingfy::services::KeepAwake> keep_awake_;

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

  // Audio separation (docs/decisions/windows-audio-separation.md): one
  // sidecar writer per captured source, fed by the mixer thread's tee with
  // the mixed packet's exact span (source data or silence) so both sidecars
  // stay sample-exact against the premixed track. Best-effort throughout: a
  // failed open/write drops that sidecar, never the recording. The `failed`
  // atomics are set from the mixer thread (one-shot, gate further writes);
  // the `ok` flags + paths are resolved by FinalizeAudioSidecars after the
  // mixer joins and consumed by FillAudioSidecarWriterFields.
  std::unique_ptr<clingfy::encoding::AudioSidecarWriter> mic_sidecar_writer_;
  std::unique_ptr<clingfy::encoding::AudioSidecarWriter>
      system_sidecar_writer_;
  std::string current_mic_sidecar_path_;
  std::string current_system_sidecar_path_;
  std::atomic<bool> mic_sidecar_failed_{false};
  std::atomic<bool> system_sidecar_failed_{false};
  bool current_mic_sidecar_ok_ = false;
  bool current_system_sidecar_ok_ = false;

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
  // Phase 10.1: same one-shot pattern for the video drain thread, whose
  // WriteVideoFrame errors were previously discarded entirely — an encoder
  // death mid-record produced no signal until Stop. Surfacing only.
  std::atomic<bool> video_write_logged_first_error_{false};
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_ENGINE_H_
