#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_RECORDER_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_RECORDER_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include <vector>

#include "Capture/Camera/camera_preview_support.h"
#include "Capture/recording_clock.h"

// Phase 9.2 — records the selected camera to a standalone raw.mov.
//
// Mirrors the CursorSampler shape: a dedicated producer with its OWN pause-aware
// RecordingClock, started in `Start()`, driven by a dedicated thread, with
// pause/resume forwarded from the engine. The camera is captured RAW + unstyled
// (no mirror/shape/chroma — those are export-time, Phase 9.5/9.6) into a
// video-only H.264 .mov via a self-contained Media Foundation pipeline:
//
//   MFCreateDeviceSource(symbolic link)
//     -> IMFSourceReader (video processing on; NV12/RGB32 negotiated)
//     -> re-stamp each sample with recording-clock time (pause-aware, rebased
//        to the first camera frame so the file starts at 0)
//     -> IMFSinkWriter (H.264, camera/raw.mov)
//
// The device source + reader + writer are created and used on the SAME capture
// thread (its own COM apartment) to avoid cross-apartment marshaling. `Start()`
// blocks until that thread reports open success/failure, so a failure is a
// clean `false` the engine treats as "continue screen-only".
//
// Everything is soft-fail: an open failure returns false; a device loss
// mid-recording stops the camera only (the screen recording is untouched),
// finalizes the partial raw.mov, and fires the optional `on_device_lost`
// callback so the engine can surface a warning.
namespace clingfy::capture {

class CameraRecorder {
 public:
  struct Config {
    // Media Foundation symbolic-link id from the video-source enumerator
    // (UTF-8). Used to reopen the exact device the user selected.
    std::string device_symlink;
    // Absolute UTF-8 path the raw H.264 .mov is written to during recording
    // (a temp file the project writer later bundles into camera/raw.mov).
    std::string temp_raw_path;
    // Preferred capture fps (the chooser caps the camera's native rate to it).
    std::uint32_t target_fps = 30;
    // The ENGINE's recording-clock elapsed time (100-ns units) at the moment the
    // camera is started, so the camera's first-frame offset is measured against
    // the SAME t=0 as the screen recording. The camera's own pause-aware clock is
    // marked in Start() (on the engine thread, before device open) and runs
    // during the device warm-up, so `start_offset_ms` captures the real
    // screen-relative time of the first camera frame (device latency included) —
    // the sync key the Phase 9.4 export uses to align the camera to the screen.
    std::int64_t base_offset_hns = 0;
    // Optional: invoked once, from the capture thread, when the device is lost
    // mid-recording. Must not block or call back into the recorder. The engine
    // uses it to post a user-facing warning. Captured by value.
    std::function<void()> on_device_lost;

    // Phase 9.3: optional live-preview sink. When set, the recorder converts the
    // latest captured frame to downscaled BGRA (off the encode path, after
    // WriteSample, throttled) and hands it here for the preview overlay to
    // paint. Unset → zero preview cost (no conversion). The buffer is reused, so
    // the callee must copy. Called from the capture thread; must not block or
    // re-enter the recorder.
    std::function<void(const std::uint8_t* bgra, int width, int height)>
        on_preview_frame;
    // Longest-side cap for the downscaled preview frame (px). The bubble is
    // small, so a modest cap keeps the conversion cheap.
    int preview_max_dim = 384;
  };

  struct Result {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t fps = 0;
    // Recording-time (ms) of the first captured frame — the export sync offset.
    std::int64_t start_offset_ms = 0;
    std::uint64_t frames_written = 0;
    bool device_lost = false;
    std::string device_id;
  };

  CameraRecorder();
  ~CameraRecorder();

  CameraRecorder(const CameraRecorder&) = delete;
  CameraRecorder& operator=(const CameraRecorder&) = delete;

  // Opens the device + sink writer, marks the clock, and starts capturing.
  // Returns false on any failure (the caller continues without a camera).
  bool Start(const Config& config);

  // Pause / resume the capture (forwarded from the engine alongside the screen
  // pause/resume). Frames during a pause are dropped; the pause-aware clock
  // keeps the raw.mov free of frozen-time gaps.
  void Pause();
  void Resume();

  // Stops capturing, finalizes raw.mov, and returns the capture summary.
  // Idempotent — a second call returns the cached result.
  Result Stop();

  bool running() const { return started_ && !stopped_; }
  std::uint64_t frames_written() const { return frames_written_.load(); }
  bool device_lost() const { return device_lost_.load(); }

  // Pure, testable timestamp helper: rebase a pause-aware recording-clock
  // timestamp (100-ns units) to the first camera frame and enforce strictly
  // increasing output timestamps. `first_hns` (< 0 until the first frame) and
  // `last_hns` (the last emitted output time, or < 0) are updated in place.
  // Returns the output sample time to stamp on the camera frame.
  static std::int64_t NextSampleTimeHns(std::int64_t elapsed_hns,
                                        std::int64_t& first_hns,
                                        std::int64_t& last_hns);

 private:
  // Runs on the capture thread: COM init -> open device/reader/writer ->
  // (report open result) -> capture loop -> finalize. `opened` is set before
  // the open result is reported back to Start().
  void ThreadMain(std::function<void(bool)> report_open);

  // Returns the pause-aware recording-clock time in 100-ns units.
  std::int64_t NowHns();

  mutable std::mutex clock_mutex_;
  RecordingClock clock_;

  Config config_;

  std::thread thread_;
  std::atomic<bool> stop_{false};
  std::atomic<bool> paused_{false};
  std::atomic<bool> device_lost_{false};
  std::atomic<std::uint64_t> frames_written_{0};

  // Negotiated capture parameters — written by the capture thread before the
  // open result is reported, read after Stop() joins (a clean sync point).
  std::uint32_t width_ = 0;
  std::uint32_t height_ = 0;
  std::uint32_t fps_ = 0;
  // First-frame recording time (100-ns), and last emitted output time, owned by
  // the capture thread.
  std::int64_t first_frame_hns_ = -1;
  std::int64_t last_sample_hns_ = -1;

  // Phase 9.3 preview state (capture thread only). Set during open; the BGRA
  // scratch buffer is reused each published frame.
  CameraPixelFormat preview_format_ = CameraPixelFormat::kNv12;
  int preview_w_ = 0;
  int preview_h_ = 0;
  std::int64_t last_preview_hns_ = -1;
  std::vector<std::uint8_t> preview_bgra_;

  bool started_ = false;
  bool stopped_ = false;
  Result result_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_RECORDER_H_
