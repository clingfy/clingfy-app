#include "Bridge/platform_thread_dispatcher.h"

#include <utility>

namespace clingfy::bridge {

namespace {

constexpr wchar_t kWindowClassName[] =
    L"ClingfyPlatformThreadDispatcherWindow";

// Custom message id for "run this callback on the platform thread."
// WM_APP is the recommended base for application-defined messages —
// the WM_USER range can collide with messages other windows route
// through their own custom protocols.
constexpr UINT kRunCallbackMsg = WM_APP + 1;

}  // namespace

PlatformThreadDispatcher& PlatformThreadDispatcher::Instance() {
  static PlatformThreadDispatcher instance;
  return instance;
}

bool PlatformThreadDispatcher::Initialize() {
  if (hwnd_ != nullptr) return true;  // already initialized

  HINSTANCE hinstance = ::GetModuleHandleW(nullptr);

  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &PlatformThreadDispatcher::WindowProc;
  wc.hInstance = hinstance;
  wc.lpszClassName = kWindowClassName;
  // RegisterClassExW returns 0 when the class is already registered.
  // Treat that as success — typically only happens after a hot
  // restart that runs Initialize() a second time within one process.
  if (::RegisterClassExW(&wc) == 0) {
    const DWORD err = ::GetLastError();
    if (err != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
  }

  // HWND_MESSAGE creates a message-only window — invisible, never
  // appears in the taskbar, never gets WM_PAINT, only used for
  // routing custom messages.
  hwnd_ = ::CreateWindowExW(
      0, kWindowClassName, L"ClingfyPlatformThreadDispatcher",
      0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, hinstance, this);
  return hwnd_ != nullptr;
}

void PlatformThreadDispatcher::Post(std::function<void()> task) {
  if (!task) return;
  if (hwnd_ == nullptr) {
    // Dispatcher not initialized — run inline. Either the runner is
    // in test mode (no FlutterWindow ever called Initialize) or
    // Initialize failed. Inline execution preserves event delivery
    // at the cost of running on the caller's thread; the publisher
    // tests rely on this branch for synchronous assertions.
    task();
    return;
  }
  auto* heap_task = new std::function<void()>(std::move(task));
  if (!::PostMessageW(hwnd_, kRunCallbackMsg, 0,
                      reinterpret_cast<LPARAM>(heap_task))) {
    // PostMessage failed (likely the message queue's per-thread
    // ~10,000-entry cap). Defensive fallback: run inline rather than
    // leak the task heap allocation and drop the event.
    (*heap_task)();
    delete heap_task;
  }
}

bool PlatformThreadDispatcher::TryPost(std::function<void()> task) {
  if (!task) return false;
  // No inline fallback on either path — see the header. A caller that reaches
  // TryPost has told us running on its own thread is not merely undesirable
  // but unsafe, so dropping is the only correct failure mode.
  if (hwnd_ == nullptr) return false;
  auto* heap_task = new std::function<void()>(std::move(task));
  if (!::PostMessageW(hwnd_, kRunCallbackMsg, 0,
                      reinterpret_cast<LPARAM>(heap_task))) {
    delete heap_task;
    return false;
  }
  return true;
}

LRESULT CALLBACK PlatformThreadDispatcher::WindowProc(HWND hwnd, UINT msg,
                                                     WPARAM wparam,
                                                     LPARAM lparam) {
  if (msg == kRunCallbackMsg) {
    auto* heap_task = reinterpret_cast<std::function<void()>*>(lparam);
    if (heap_task != nullptr) {
      try {
        (*heap_task)();
      } catch (...) {
        // Swallow — a throwing callback should not crash the message
        // loop. Event-publisher emits are noexcept in practice
        // (Flutter sinks don't throw), so this is purely defensive.
      }
      delete heap_task;
    }
    return 0;
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

}  // namespace clingfy::bridge
