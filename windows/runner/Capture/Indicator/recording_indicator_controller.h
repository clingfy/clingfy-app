#ifndef RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_CONTROLLER_H_
#define RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_CONTROLLER_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <future>
#include <mutex>
#include <thread>

// Slice 1 (Windows recording indicator): the always-on-top pill shown WHILE
// recording, with a native-ticking `HH:MM:SS` timer. This is the window /
// thread / GDI half; the pure state + formatting + placement logic lives in
// `recording_indicator_model.*` (unit-tested headless).
//
// The window mirrors `CameraFloatingOverlay`: a topmost, non-activating
// `WS_POPUP` tool window on its own message-loop thread, excluded from screen
// capture via `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` so the pill is
// never burned into the recording. Slice 1 is DISPLAY-ONLY — it shows, times,
// and hides; the pause/stop/resume controls and the reverse tap callbacks land
// in Slice 2.
//
// Lifecycle / threading contract (deliberately different from the camera
// overlay, to avoid a teardown deadlock): the overlay thread is created lazily
// on the first `Show(...)` and PERSISTS, idle+hidden, between recordings. The
// engine calls `Show(...)` when a recording goes live and `Hide()` when it
// ends. `Hide()` is NON-BLOCKING — it never joins the overlay thread — because
// the engine calls it while holding its recording mutex, and the overlay
// thread's duration provider takes that same mutex; joining under the lock
// would deadlock. The thread is joined only by `Shutdown()`, at app teardown,
// off any lock.
namespace clingfy::capture {

class RecordingIndicatorController {
 public:
  // Process singleton — the recording engine is itself a singleton and drives
  // this from its state transitions; there is never more than one indicator.
  static RecordingIndicatorController& Instance();

  RecordingIndicatorController(const RecordingIndicatorController&) = delete;
  RecordingIndicatorController& operator=(const RecordingIndicatorController&) =
      delete;

  // Show the recording pill (creating the overlay window + thread on first
  // call). `duration_provider` returns the elapsed WHOLE seconds to render and
  // is called on the overlay thread once per second; it must be safe to call at
  // any time after this returns (the engine wires it to a pause-aware,
  // mutex-guarded elapsed accessor). Idempotent: calling again while visible
  // just refreshes the provider.
  void Show(std::function<std::uint64_t()> duration_provider);

  // Hide the pill. Non-blocking: posts a hide to the overlay thread and returns
  // immediately, leaving the (idle) thread alive for the next recording. Safe
  // to call under the engine's recording lock. Idempotent.
  void Hide();

  // Tear the overlay window + thread down and join. Call at app shutdown, OFF
  // any lock. Idempotent.
  void Shutdown();

  // Test / diagnostics: whether the pill is currently shown.
  bool visible_for_testing() const { return visible_.load(); }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  RecordingIndicatorController() = default;
  ~RecordingIndicatorController();

  // Spawn the overlay thread + create the hidden window. Blocks until the
  // window is up (or creation failed). No-op when already running.
  bool EnsureRunning();
  void ThreadMain(std::promise<bool>* ready);
  void Paint(HWND hwnd);
  // Position the pill in the top-right of the work area of whatever monitor it
  // currently sits on, DPI-scaled. Runs on the overlay thread.
  void PlaceWindow(HWND hwnd);

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> visible_{false};
  std::atomic<HWND> hwnd_{nullptr};
  DWORD thread_id_ = 0;

  // The elapsed-seconds source, swapped under `provider_mutex_` and read on the
  // overlay thread each tick. Null before the first Show.
  std::mutex provider_mutex_;
  std::function<std::uint64_t()> duration_provider_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_CONTROLLER_H_
