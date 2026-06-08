#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_FLOATING_OVERLAY_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_FLOATING_OVERLAY_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

// Phase 9.3.2 — floating camera bubble (macOS-like): a Win32 topmost, opaque,
// non-activating, draggable window that paints the live camera frame while
// recording, EXCLUDED from screen capture via
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) so it is not burned into
// screen.mov.
//
// It runs on its own thread + message loop (never blocks the platform thread),
// is fed downscaled BGRA frames by the 9.2 CameraRecorder via PublishBgra, and
// is dragged by the user (WM_NCHITTEST → HTCAPTION). It starts HIDDEN; the
// engine calls Show() only when the user's preview mode is "floating" AND
// capture-exclusion succeeded (`wda_excluded()`), so a non-excluded floating
// window can never be burned into the recording. On hardware where
// WDA_EXCLUDEFROMCAPTURE reports success but the window is invisible (some
// hybrid GPUs), the user switches to the in-app texture preview — that fallback
// is undetectable in code (every screen-read API respects the exclusion), so it
// is a user action, not an auto probe.
namespace clingfy::capture {

struct FloatingPlacement {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  bool rounded = true;
};

class CameraFloatingOverlay {
 public:
  CameraFloatingOverlay() = default;
  ~CameraFloatingOverlay();

  CameraFloatingOverlay(const CameraFloatingOverlay&) = delete;
  CameraFloatingOverlay& operator=(const CameraFloatingOverlay&) = delete;

  // Create the (hidden) window + apply capture-exclusion. Spawns the overlay
  // thread and blocks until the window is up (or creation failed). Returns false
  // on failure — the caller continues without a floating bubble.
  bool Start(const FloatingPlacement& placement);

  // Show / hide the bubble (window ops marshaled to the overlay thread).
  void Show();
  void Hide();

  // Feed the latest camera frame (tightly-packed BGRA, stride = width*4).
  // Thread-safe; a no-op before Start / after Stop.
  void PublishBgra(const std::uint8_t* bgra, int width, int height);

  // Tear the window + thread down. Idempotent. Call after the frame producer
  // (CameraRecorder) is stopped so no PublishBgra races teardown.
  void Stop();

  bool running() const { return running_.load(); }

  // True only when SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) succeeded —
  // i.e. showing this window will NOT burn it into screen.mov. The engine must
  // never Show() the floating bubble when this is false.
  bool wda_excluded() const { return wda_excluded_.load(); }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  void ThreadMain(FloatingPlacement placement, std::promise<bool>* ready);
  void Paint(HWND hwnd);

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> wda_excluded_{false};
  std::atomic<HWND> hwnd_{nullptr};
  DWORD thread_id_ = 0;

  std::mutex frame_mutex_;
  std::vector<std::uint8_t> frame_bgra_;
  int frame_w_ = 0;
  int frame_h_ = 0;
  bool dirty_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_FLOATING_OVERLAY_H_
