#include "Capture/Cursor/cursor_click_hook.h"

#include <windows.h>

#include <future>
#include <mutex>
#include <utility>

namespace clingfy::capture {

namespace {

// The active hook instance. A `WH_MOUSE_LL` proc is a free function with no
// user-data parameter, so it reaches its owner through this file-scope pointer.
// Guarded by `g_active_mutex` because Start/Stop (engine thread) publish/clear it
// while the proc (hook thread) reads it. Only one recording is active at a time.
std::mutex g_active_mutex;
CursorClickHook* g_active = nullptr;

LRESULT CALLBACK MouseLowLevelProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION) {
    CursorClickHook::Button button = CursorClickHook::Button::kLeft;
    bool is_click = false;
    bool down = false;
    switch (wparam) {
      case WM_LBUTTONDOWN: button = CursorClickHook::Button::kLeft; is_click = true; down = true; break;
      case WM_LBUTTONUP:   button = CursorClickHook::Button::kLeft; is_click = true; down = false; break;
      case WM_RBUTTONDOWN: button = CursorClickHook::Button::kRight; is_click = true; down = true; break;
      case WM_RBUTTONUP:   button = CursorClickHook::Button::kRight; is_click = true; down = false; break;
      case WM_MBUTTONDOWN: button = CursorClickHook::Button::kMiddle; is_click = true; down = true; break;
      case WM_MBUTTONUP:   button = CursorClickHook::Button::kMiddle; is_click = true; down = false; break;
      default: break;
    }
    if (is_click && lparam != 0) {
      const auto* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
      CursorClickHook* owner = nullptr;
      {
        std::lock_guard<std::mutex> lock(g_active_mutex);
        owner = g_active;
      }
      if (owner != nullptr) {
        owner->OnRawClick(static_cast<std::int32_t>(info->pt.x),
                          static_cast<std::int32_t>(info->pt.y), button, down);
      }
    }
  }
  return ::CallNextHookEx(nullptr, code, wparam, lparam);
}

}  // namespace

CursorClickHook::~CursorClickHook() { Stop(); }

bool CursorClickHook::Start(NowMsFn now_ms) {
  if (running_) {
    return false;
  }
  // Reserve the single active slot atomically on the CALLING thread, before the
  // worker spawns, so the "one hook per process" contract is self-enforced (not
  // merely held by the caller's external lock). The hook proc only ever fires
  // after SetWindowsHookEx installs it on the worker, by which point g_active is
  // already published, so it is always a valid pointer when the proc reads it.
  {
    std::lock_guard<std::mutex> lock(g_active_mutex);
    if (g_active != nullptr) {
      return false;  // another hook is already active in this process.
    }
    g_active = this;
  }
  now_ms_ = std::move(now_ms);

  std::promise<bool> installed_promise;
  std::future<bool> installed = installed_promise.get_future();

  thread_ = std::thread([this, p = std::move(installed_promise)]() mutable {
    thread_id_ = ::GetCurrentThreadId();
    const HHOOK hook = ::SetWindowsHookExW(WH_MOUSE_LL, &MouseLowLevelProc,
                                           ::GetModuleHandleW(nullptr), 0);
    if (hook == nullptr) {
      p.set_value(false);
      return;
    }
    p.set_value(true);

    // Pump messages so the low-level hook is serviced; exit on WM_QUIT
    // (posted by Stop via PostThreadMessage).
    MSG msg{};
    while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    ::UnhookWindowsHookEx(hook);
  });

  const bool ok = installed.get();
  if (!ok) {
    if (thread_.joinable()) {
      thread_.join();
    }
    {
      std::lock_guard<std::mutex> lock(g_active_mutex);
      if (g_active == this) {
        g_active = nullptr;
      }
    }
    now_ms_ = nullptr;
    return false;
  }
  running_ = true;
  return true;
}

void CursorClickHook::Stop() {
  if (!running_) {
    if (thread_.joinable()) {
      thread_.join();
    }
    return;
  }
  if (thread_id_ != 0) {
    ::PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
  }
  if (thread_.joinable()) {
    thread_.join();
  }
  running_ = false;
  thread_id_ = 0;
  // The worker has joined (no more proc invocations), so releasing the active
  // slot + clearing now_ms_ here cannot race the hook proc.
  now_ms_ = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_active_mutex);
    if (g_active == this) {
      g_active = nullptr;
    }
  }
  std::lock_guard<std::mutex> lock(queue_mutex_);
  queue_.clear();
}

void CursorClickHook::OnRawClick(std::int32_t screen_x, std::int32_t screen_y,
                                 Button button, bool down) {
  Event event;
  event.t_ms = NowMs();
  event.screen_x = screen_x;
  event.screen_y = screen_y;
  event.button = button;
  event.down = down;
  std::lock_guard<std::mutex> lock(queue_mutex_);
  queue_.push_back(event);
}

std::int64_t CursorClickHook::NowMs() const {
  return now_ms_ ? now_ms_() : 0;
}

std::vector<CursorClickHook::Event> CursorClickHook::Drain() {
  std::vector<Event> out;
  std::lock_guard<std::mutex> lock(queue_mutex_);
  out.swap(queue_);
  return out;
}

}  // namespace clingfy::capture
