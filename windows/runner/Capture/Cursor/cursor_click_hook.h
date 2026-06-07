#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_CLICK_HOOK_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_CLICK_HOOK_H_

#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

// Phase 8.1 — global mouse-click capture via a `WH_MOUSE_LL` low-level hook.
//
// A low-level mouse hook MUST live on a thread that pumps a message loop, and
// its proc MUST return fast or Windows silently removes it past
// `LowLevelHooksTimeout`. So this owns a dedicated thread that installs the hook
// and runs its own `GetMessage` loop; the proc does the minimum — timestamp +
// classify + enqueue — and the sampler thread drains the queue.
//
// Click capture is additive: if the hook fails to install, `Start` returns false
// and recording continues without clicks (the cursor position track is
// unaffected). Only one hook is active per process at a time (one recording).
namespace clingfy::capture {

class CursorClickHook {
 public:
  enum class Button { kLeft, kRight, kMiddle };

  struct Event {
    std::int64_t t_ms = 0;  // recording-time ms (pause-aware), from `now_ms`.
    std::int32_t screen_x = 0;
    std::int32_t screen_y = 0;
    Button button = Button::kLeft;
    bool down = false;  // true = press, false = release.
  };

  // Returns the current recording-time ms. Called from the hook proc, so it must
  // be cheap and non-blocking.
  using NowMsFn = std::function<std::int64_t()>;

  CursorClickHook() = default;
  ~CursorClickHook();

  CursorClickHook(const CursorClickHook&) = delete;
  CursorClickHook& operator=(const CursorClickHook&) = delete;

  // Spawn the hook thread and install the hook. Returns true once the hook is
  // confirmed installed (the worker signals back via a promise), false on
  // failure (e.g. a hook already active, or SetWindowsHookEx denied).
  bool Start(NowMsFn now_ms);

  // Unhook, quit the worker's message loop, and join. Idempotent.
  void Stop();

  // Pull and clear all events enqueued since the last drain (sampler thread).
  std::vector<Event> Drain();

  // Entry point for the file-scope `WH_MOUSE_LL` proc (defined in the .cpp,
  // where the Win32 types live). Stamps the recording time and enqueues. Public
  // only so the proc can reach it through the active-instance pointer; not for
  // general use.
  void OnRawClick(std::int32_t screen_x, std::int32_t screen_y, Button button,
                  bool down);

 private:
  std::int64_t NowMs() const;

  std::thread thread_;
  unsigned long thread_id_ = 0;  // DWORD; the worker's thread id for WM_QUIT.
  NowMsFn now_ms_;

  std::mutex queue_mutex_;
  std::vector<Event> queue_;
  bool running_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_CLICK_HOOK_H_
