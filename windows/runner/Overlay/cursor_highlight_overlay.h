#ifndef RUNNER_OVERLAY_CURSOR_HIGHLIGHT_OVERLAY_H_
#define RUNNER_OVERLAY_CURSOR_HIGHLIGHT_OVERLAY_H_

#include <windows.h>

#include <atomic>
#include <chrono>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

#include "Overlay/cursor_highlight_model.h"

// The live cursor highlight window (see cursor_highlight_model.h for what it
// draws and why it is recorded). Port of macOS `CursorHighlighter`.
//
// A topmost, click-through, per-pixel-alpha layered popup on its own
// message-loop thread, created lazily on the first show and kept, hidden,
// between uses (the RecordingIndicatorController lifecycle). While shown, a
// ~60 Hz timer follows GetCursorPos and watches the left button for the click
// pulse. Polling rather than a WH_MOUSE_LL hook: the recording's
// CursorClickHook already owns the process's one low-level hook, and a pulse
// missed for a sub-16 ms click is cosmetic.
//
// The inputs come from two places, both non-blocking and safe under the
// recording engine's lock:
//   * Dart, through setCursorHighlightEnabled / setCursorHighlightLinkedTo-
//     Recording (pushed at startup and on every toggle);
//   * the engine, on start / pause / resume / every end path.
namespace clingfy::overlay {

class CursorHighlightOverlay {
 public:
  static CursorHighlightOverlay& Instance();

  CursorHighlightOverlay(const CursorHighlightOverlay&) = delete;
  CursorHighlightOverlay& operator=(const CursorHighlightOverlay&) = delete;

  void SetEnabled(bool enabled);
  void SetLinkedToRecording(bool linked);

  // A session went live (or resumed: `actively_recording` true) or paused
  // (false). `session_disabled` is the request's disableCursorHighlight.
  void SetRecordingState(bool actively_recording, bool session_disabled);
  // Every end path: not recording, and the session's suppression cleared.
  void ClearRecordingState();

  // Join the thread. App shutdown only, off any lock. Idempotent.
  void Shutdown();

  // Test / diagnostics.
  bool IsShownForTesting() const { return shown_.load(); }
  bool WantsShowForTesting() const;

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  CursorHighlightOverlay() = default;
  ~CursorHighlightOverlay();

  void Reconcile();
  bool EnsureRunning();
  void ThreadMain(std::promise<bool>* ready);
  // Overlay thread only.
  void OnShow(HWND hwnd);
  void OnHide(HWND hwnd);
  void OnTick(HWND hwnd);
  void Present(HWND hwnd, POINT cursor, bool redraw);

  mutable std::mutex state_mutex_;
  bool enabled_ = false;
  bool linked_ = true;
  bool actively_recording_ = false;
  bool session_disabled_ = false;

  std::thread thread_;
  DWORD thread_id_ = 0;
  std::atomic<HWND> hwnd_{nullptr};
  std::atomic<bool> shown_{false};

  // Overlay thread only.
  int size_px_ = 0;
  unsigned dpi_ = 0;
  POINT last_cursor_{LONG_MIN, LONG_MIN};
  bool button_was_down_ = false;
  bool pulse_drawn_ = false;
  std::chrono::steady_clock::time_point click_at_{};
  bool has_click_ = false;
  std::vector<std::uint32_t> pixels_;
};

}  // namespace clingfy::overlay

#endif  // RUNNER_OVERLAY_CURSOR_HIGHLIGHT_OVERLAY_H_
