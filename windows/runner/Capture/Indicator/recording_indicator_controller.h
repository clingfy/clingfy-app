#ifndef RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_CONTROLLER_H_
#define RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_CONTROLLER_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <future>
#include <mutex>
#include <optional>
#include <thread>

#include "Capture/Indicator/recording_indicator_model.h"

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

  // Update the pill's visual state (recording <-> paused <-> stopping). Drives
  // which controls are drawn (pause vs resume) and the paused/stopping styling.
  // Non-blocking (posts a repaint to the overlay thread); safe under the
  // engine's recording lock. A no-op before Show / after Hide.
  void SetState(IndicatorVisualState state);

  // Pin / unpin the pill (Slice 3, `setRecordingIndicatorPinned`). Pinned snaps
  // it to the top-right corner and makes it non-movable; unpinned lets the user
  // drag it and restores the last dragged position (macOS parity — the dragged
  // position is remembered for the app session only, never persisted to disk).
  // Cached on the controller because Dart pushes `pinned` on startup + toggle,
  // never on show. Non-blocking; safe under the engine's recording lock.
  void SetPinned(bool pinned);

  // Hide the pill. Non-blocking: posts a hide to the overlay thread and returns
  // immediately, leaving the (idle) thread alive for the next recording. Safe
  // to call under the engine's recording lock. Idempotent.
  void Hide();

  // Tear the overlay window + thread down and join. Call at app shutdown, OFF
  // any lock. Idempotent.
  void Shutdown();

  // Test / diagnostics: whether the pill is currently shown.
  bool visible_for_testing() const { return visible_.load(); }
  IndicatorVisualState state_for_testing() const { return state_.load(); }
  bool pinned_for_testing() const { return pinned_.load(); }

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
  // Position the pill: top-right (DPI-scaled) when pinned or never dragged,
  // otherwise at the remembered drag origin clamped to the current work area.
  // Runs on the overlay thread.
  void PlaceWindow(HWND hwnd);
  // Fire the reverse call for the control at the given client point (if any),
  // deriving pause vs resume from the current visual state. Overlay thread.
  void HandleClick(HWND hwnd, int x, int y);
  // Drag-end write-back (WM_EXITSIZEMOVE): clamp the dropped window into the
  // work area and remember the origin for the next show. Overlay thread.
  void OnDragEnded(HWND hwnd);

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> visible_{false};
  std::atomic<HWND> hwnd_{nullptr};
  std::atomic<IndicatorVisualState> state_{IndicatorVisualState::kHidden};
  std::atomic<bool> can_pause_resume_{true};
  // Pinned: written from the platform thread (SetPinned), read on the overlay
  // thread (WM_NCHITTEST / PlaceWindow) — hence atomic.
  std::atomic<bool> pinned_{false};
  DWORD thread_id_ = 0;

  // Last position the user dragged the pill to (top-left, screen coords). Set
  // in WM_EXITSIZEMOVE, read in PlaceWindow — BOTH on the overlay thread, so no
  // lock is needed (contrast pinned_). Empty until the first drag; in-memory
  // for the app session only (macOS parity — never persisted to disk).
  std::optional<POINT> last_origin_;

  // The elapsed-seconds source, swapped under `provider_mutex_` and read on the
  // overlay thread each tick. Null before the first Show.
  std::mutex provider_mutex_;
  std::function<std::uint64_t()> duration_provider_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_CONTROLLER_H_
