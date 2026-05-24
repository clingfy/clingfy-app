#ifndef RUNNER_CAPTURE_RECORDING_ENGINE_H_
#define RUNNER_CAPTURE_RECORDING_ENGINE_H_

#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#include "Capture/recording_clock.h"
#include "Capture/recording_session_state.h"

namespace clingfy::graphics {
class D3DDevice;
}

namespace clingfy::capture {
class VideoFrameQueue;
class WgcDisplayCaptureBackend;
struct WgcCaptureStats;
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

  bool IsRecording() const;
  RecordingState state() const;
  std::string session_id() const;

  // Diagnostics snapshot — used by manual smoke-tests in Phase 3B to
  // confirm frames are arriving and by Phase 3C+ to surface drop counts.
  // Returns zeros when no capture is in flight.
  struct CaptureDiagnostics {
    std::uint32_t frame_width = 0;
    std::uint32_t frame_height = 0;
    std::uint64_t frames_received = 0;
    std::uint64_t frames_dropped = 0;
  };
  CaptureDiagnostics Diagnostics() const;

  // Test seam: resets the singleton's state to Idle and clears the session
  // id. Not safe to call while a real recording is in flight (only Phase
  // 3A's skeleton path is exercised today, but later PRs that bring in
  // capture pipelines must avoid this from production code).
  void ForceResetForTesting();

 private:
  RecordingEngine();
  ~RecordingEngine();

  // Tears the capture pipeline down (backend → D3D device → queue) without
  // touching state-machine state. Called from Stop / failure paths so the
  // caller does not have to hand-roll the teardown order.
  void TeardownPipeline();

  mutable std::mutex mutex_;
  RecordingSessionState session_;
  RecordingClock clock_;

  // Capture pipeline (Phase 3B). Held as unique_ptrs so the engine header
  // can stay free of D3D / WinRT includes; the implementation owns the
  // full types.
  std::unique_ptr<clingfy::graphics::D3DDevice> d3d_device_;
  std::unique_ptr<VideoFrameQueue> frame_queue_;
  std::unique_ptr<WgcDisplayCaptureBackend> capture_backend_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_ENGINE_H_
