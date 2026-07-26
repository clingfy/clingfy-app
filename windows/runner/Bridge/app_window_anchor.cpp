#include "Bridge/app_window_anchor.h"

#include <atomic>

namespace clingfy {

namespace {

// Set on the platform thread at startup, read from each overlay's own UI
// thread, so the handle needs to be atomic.
std::atomic<HWND> g_main_window{nullptr};

// Full primary-display bounds. Used only when no monitor can be resolved at
// all, which in practice means a session with no attached display.
RECT PrimaryFallback() {
  return RECT{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
              ::GetSystemMetrics(SM_CYSCREEN)};
}

// Work area of `mon`, or nullopt-ish via `ok` when the monitor can't be queried.
bool WorkAreaOf(HMONITOR mon, RECT* out) {
  if (mon == nullptr) {
    return false;
  }
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (::GetMonitorInfoW(mon, &mi) == 0) {
    return false;
  }
  *out = mi.rcWork;
  return true;
}

}  // namespace

void SetMainAppWindow(HWND hwnd) { g_main_window.store(hwnd); }

HWND MainAppWindow() { return g_main_window.load(); }

RECT AnchorWorkArea(HWND fallback) {
  RECT work{};

  // Preferred: the display showing the main app window. MONITOR_DEFAULTTONEAREST
  // keeps a partly off-screen main window resolving to the display it mostly
  // occupies.
  if (HWND main = g_main_window.load();
      main != nullptr && ::IsWindow(main) != 0) {
    if (WorkAreaOf(::MonitorFromWindow(main, MONITOR_DEFAULTTONEAREST), &work)) {
      return work;
    }
  }

  // The main window is gone or unqueryable — fall back to the caller's own
  // display so behavior matches the pre-anchor code rather than jumping.
  if (fallback != nullptr &&
      WorkAreaOf(::MonitorFromWindow(fallback, MONITOR_DEFAULTTOPRIMARY),
                 &work)) {
    return work;
  }

  return PrimaryFallback();
}

RECT WorkAreaForWindow(HWND hwnd) {
  RECT work{};
  if (hwnd != nullptr &&
      WorkAreaOf(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &work)) {
    return work;
  }
  return PrimaryFallback();
}

RECT WorkAreaForPoint(POINT pt) {
  RECT work{};
  if (WorkAreaOf(::MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), &work)) {
    return work;
  }
  return PrimaryFallback();
}

}  // namespace clingfy
