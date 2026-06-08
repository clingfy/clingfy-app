#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_PREVIEW_OVERLAY_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_PREVIEW_OVERLAY_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

#include "Capture/Camera/camera_preview_support.h"

// Phase 9.3 — live camera preview bubble: a Win32 layered, topmost,
// non-activating window that paints the latest camera frame while recording.
//
// It runs on its OWN thread with its own message loop (so it never blocks the
// platform thread). The 9.2 CameraRecorder publishes downscaled BGRA frames via
// PublishBgra (thread-safe); a paint timer blits the latest one. The window is
// created with WS_EX_LAYERED and made visible via SetLayeredWindowAttributes
// (per the Win32 docs a layered window stays invisible until that call), and an
// optional rounded region gives a soft-cornered bubble.
//
// Everything is best-effort: if the window cannot be created, Start returns
// false and the caller continues recording without a bubble. The class owns no
// camera or recording state — it is purely a display surface.
namespace clingfy::capture {

class CameraPreviewOverlay {
 public:
  CameraPreviewOverlay() = default;
  ~CameraPreviewOverlay();

  CameraPreviewOverlay(const CameraPreviewOverlay&) = delete;
  CameraPreviewOverlay& operator=(const CameraPreviewOverlay&) = delete;

  // Create + show the bubble at `placement`. Spawns the overlay thread and
  // blocks until the window is up (or creation failed). Returns false on
  // failure — the caller treats that as "no preview", non-fatal.
  bool Start(const BubblePlacement& placement);

  // Hand the latest camera frame (tightly-packed BGRA, stride = width*4) to the
  // overlay. Thread-safe; a no-op before Start / after Stop. Copies the bytes
  // (the caller's buffer is reused), so the pointer need not outlive the call.
  void PublishBgra(const std::uint8_t* bgra, int width, int height);

  // Tear the window + thread down. Idempotent. MUST be called before the
  // frame-producer (CameraRecorder) is destroyed, and the producer's thread
  // MUST already be stopped, so no PublishBgra races teardown.
  void Stop();

  bool running() const { return running_.load(); }

  // Window procedure. Public only because the class registration (in an
  // anonymous-namespace helper) needs its address; not meant to be called
  // directly.
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  void ThreadMain(BubblePlacement placement, std::promise<bool>* ready);
  void Paint(HWND hwnd);

  std::thread thread_;
  std::atomic<bool> running_{false};
  DWORD thread_id_ = 0;

  // Latest frame, guarded. `dirty_` marks a new frame for the paint timer.
  std::mutex frame_mutex_;
  std::vector<std::uint8_t> frame_bgra_;
  int frame_w_ = 0;
  int frame_h_ = 0;
  bool dirty_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_PREVIEW_OVERLAY_H_
