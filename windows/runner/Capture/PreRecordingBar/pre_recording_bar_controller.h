#ifndef RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_CONTROLLER_H_
#define RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_CONTROLLER_H_

#include <windows.h>

#include <atomic>
#include <future>
#include <mutex>
#include <thread>

#include "Capture/PreRecordingBar/pre_recording_bar_model.h"

// Slice 4 (Windows pre-recording bar): the always-on-top floating control bar
// shown BEFORE (and during) a recording — record button, source pickers,
// mic/camera/system toggles, update + pause/resume. This is the window / thread
// / GDI half; the pure render logic (which buttons show, their style, the
// layout, and the visibility gate) lives in `pre_recording_bar_model.*`
// (unit-tested headless).
//
// The window mirrors the recording indicator: a topmost, non-activating
// `WS_POPUP` tool window on its own message-loop thread, excluded from screen
// capture via `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` so the bar is
// never burned into the recording (a deliberate divergence from macOS, whose
// panel is not excluded — burning control chrome into the video is worse).
// Slice 4 is DISPLAY-ONLY: it shows, styles buttons from the pushed state,
// sizes itself to the visible button set, and hides. The button taps + reverse
// `preRecordingBarAction` callbacks land in Slice 5; the native pickers in
// Slice 6.
//
// Threading contract (mirrors the indicator): the overlay thread is created
// lazily the first time the bar needs to be visible and PERSISTS, idle+hidden,
// afterwards. Dart drives everything via the method channel — `SetEnabled`,
// `Show`, `Toggle`, `SetState` — off the platform thread, never under the
// engine's recording lock. Every public method is non-blocking apart from the
// one-time window creation inside `EnsureRunning`.
namespace clingfy::capture {

class PreRecordingBarController {
 public:
  // Process singleton — Dart drives a single bar; there is never more than one.
  static PreRecordingBarController& Instance();

  PreRecordingBarController(const PreRecordingBarController&) = delete;
  PreRecordingBarController& operator=(const PreRecordingBarController&) =
      delete;

  // `setPreRecordingBarEnabled` / `setPreRecordingBarVisible`: the Settings
  // "floating control bar" toggle. When false the bar never shows regardless of
  // phase; when true it shows whenever the phase + dismissed state allow.
  void SetEnabled(bool enabled);

  // `showPreRecordingBar`: explicit show request — clears the per-cycle
  // "dismissed" flag so a bar the user closed reappears, then re-applies
  // visibility. No-op while disabled.
  void Show();

  // `togglePreRecordingBar`: hide it (dismiss for this cycle) when visible,
  // otherwise explicitly show it.
  void Toggle();

  // `setPreRecordingBarState`: push the latest workflow/source state. Restyles
  // + resizes the button row and re-applies visibility. A non-idle -> idle
  // transition resets the per-cycle dismissed flag so the bar returns for the
  // next recording cycle (macOS `setAppPhase`).
  void SetState(const PreRecordingBarInputs& inputs);

  // Tear the overlay window + thread down and join. Call at app shutdown, OFF
  // any lock. Idempotent.
  void Shutdown();

  // Test / diagnostics.
  bool visible_for_testing() const { return visible_.load(); }
  bool enabled_for_testing() const { return enabled_.load(); }
  bool dismissed_for_testing() const { return dismissed_.load(); }
  PreRecordingBarInputs inputs_for_testing();
  // When set, `EnsureRunning` becomes a no-op so unit tests can exercise the
  // state/routing paths without creating a real window on the CI agent.
  static void set_suppress_window_for_testing(bool suppress);

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  PreRecordingBarController() = default;
  ~PreRecordingBarController();

  // Spawn the overlay thread + create the hidden window. Blocks until the
  // window is up (or creation failed). No-op when already running or suppressed
  // for testing.
  bool EnsureRunning();
  void ThreadMain(std::promise<bool>* ready);
  void Paint(HWND hwnd);
  // Size the bar to the current button set + center it near the bottom of the
  // work area, then position topmost. Runs on the overlay thread.
  void PlaceWindow(HWND hwnd);
  // Recompute whether the bar should be visible (enabled AND not dismissed AND
  // the pushed state's phase/countdown allow it) and post the show/hide + a
  // resize/repaint to the overlay thread. Lazily starts the thread when a show
  // is needed. Safe to call from the platform thread.
  void ApplyVisibility();

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> visible_{false};
  std::atomic<HWND> hwnd_{nullptr};
  // Dart's persisted "floating control bar" toggle defaults to on (mirrors the
  // macOS `preRecordingBarEnabled = true`); Dart re-pushes the real value on
  // startup + on change.
  std::atomic<bool> enabled_{true};
  // Set when the user closes/toggles the bar away; cleared on an explicit show
  // or a return to idle. Per recording cycle, matching macOS.
  std::atomic<bool> dismissed_{false};
  DWORD thread_id_ = 0;

  // The latest pushed render state + the previous phase (to detect the
  // ->idle transition). Written from the platform thread (SetState), read on
  // the overlay thread (Paint / PlaceWindow) — guarded by `state_mutex_`.
  std::mutex state_mutex_;
  PreRecordingBarInputs inputs_;
  int last_phase_ = 0;

  static std::atomic<bool> suppress_window_for_testing_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_CONTROLLER_H_
