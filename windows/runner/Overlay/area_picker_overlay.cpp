#include "Overlay/area_picker_overlay.h"

#include <windows.h>
#include <windowsx.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <optional>
#include <vector>

#include "Bridge/Devices/display_enumerator.h"
#include "Overlay/area_picker_geometry.h"

namespace clingfy::overlay {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyAreaPickerOverlay";
// Backdrop opacity (0..255). Dim enough to read as "selection mode" without
// fully hiding what's behind it.
constexpr BYTE kBackdropAlpha = 110;

// Shared across every per-monitor overlay window for one Pick() call.
struct PickSession {
  bool done = false;
  bool cancelled = false;
  std::optional<PickedArea> result;
};

// Guards against re-entry: PickArea() runs a nested message loop on the
// platform thread, so a re-entrant pickAreaRecordingRegion (or another posted
// platform task) could otherwise launch a SECOND overlay set mid-pick. A pick
// in progress makes a second PickArea() return immediately (the caller replies
// a clean cancel).
std::atomic<bool> g_pick_in_progress{false};

// Per-window state, stored in GWLP_USERDATA.
struct OverlayWindow {
  PickSession* session = nullptr;
  RECT monitor_rect{};  // virtual-desktop coords; left/top may be negative.
  std::uint32_t mon_w = 0;
  std::uint32_t mon_h = 0;
  std::int64_t display_id = 0;
  bool dragging = false;
  LocalPoint start{};
  LocalPoint cur{};
  // Cached double-buffer. The window is fixed-size, so create it once and reuse
  // it instead of allocating a full-monitor bitmap on every mouse-move repaint.
  HDC mem_dc = nullptr;
  HBITMAP mem_bmp = nullptr;
  HBITMAP mem_old_bmp = nullptr;
};

POINT ScreenMousePos() {
  const DWORD packed = ::GetMessagePos();
  return POINT{GET_X_LPARAM(packed), GET_Y_LPARAM(packed)};
}

void PaintOverlay(HWND hwnd, OverlayWindow* ow) {
  PAINTSTRUCT ps{};
  HDC hdc = ::BeginPaint(hwnd, &ps);
  RECT client{};
  ::GetClientRect(hwnd, &client);

  // Lazily create the cached back-buffer (the window is fixed-size). Reusing it
  // avoids allocating a full-monitor bitmap on every mouse-move repaint.
  if (ow != nullptr && ow->mem_dc == nullptr) {
    ow->mem_dc = ::CreateCompatibleDC(hdc);
    ow->mem_bmp = ::CreateCompatibleBitmap(hdc, client.right, client.bottom);
    if (ow->mem_dc != nullptr && ow->mem_bmp != nullptr) {
      ow->mem_old_bmp =
          static_cast<HBITMAP>(::SelectObject(ow->mem_dc, ow->mem_bmp));
    }
  }

  // GDI-failure (or no per-window state) fallback: paint the dim backdrop
  // straight to the window DC and bail — no double buffer.
  if (ow == nullptr || ow->mem_dc == nullptr || ow->mem_bmp == nullptr) {
    HBRUSH backdrop = ::CreateSolidBrush(RGB(20, 20, 28));
    ::FillRect(hdc, &client, backdrop);
    ::DeleteObject(backdrop);
    ::EndPaint(hwnd, &ps);
    return;
  }

  HDC mem = ow->mem_dc;
  HBRUSH backdrop = ::CreateSolidBrush(RGB(20, 20, 28));
  ::FillRect(mem, &client, backdrop);
  ::DeleteObject(backdrop);

  if (ow->dragging) {
    // start/cur are monitor-local, which equals client coordinates because the
    // window covers exactly this monitor (client origin == monitor top-left).
    RECT sel{};
    sel.left = std::min(ow->start.x, ow->cur.x);
    sel.top = std::min(ow->start.y, ow->cur.y);
    sel.right = std::max(ow->start.x, ow->cur.x);
    sel.bottom = std::max(ow->start.y, ow->cur.y);

    HBRUSH fill = ::CreateSolidBrush(RGB(90, 110, 160));
    ::FillRect(mem, &sel, fill);
    ::DeleteObject(fill);
    HBRUSH border = ::CreateSolidBrush(RGB(0, 150, 255));
    ::FrameRect(mem, &sel, border);
    ::DeleteObject(border);
  }

  ::BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, SRCCOPY);
  ::EndPaint(hwnd, &ps);
}

// Release a window's cached back-buffer (restore the original bitmap first).
void ReleaseBackBuffer(OverlayWindow* ow) {
  if (ow == nullptr || ow->mem_dc == nullptr) {
    return;
  }
  if (ow->mem_old_bmp != nullptr) {
    ::SelectObject(ow->mem_dc, ow->mem_old_bmp);
  }
  if (ow->mem_bmp != nullptr) {
    ::DeleteObject(ow->mem_bmp);
  }
  ::DeleteDC(ow->mem_dc);
  ow->mem_dc = nullptr;
  ow->mem_bmp = nullptr;
  ow->mem_old_bmp = nullptr;
}

void CancelSession(OverlayWindow* ow) {
  if (ow != nullptr && ow->session != nullptr) {
    ow->session->cancelled = true;
    ow->session->done = true;
  }
}

LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  auto* ow = reinterpret_cast<OverlayWindow*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));

  switch (msg) {
    case WM_LBUTTONDOWN: {
      if (ow == nullptr) {
        break;
      }
      ::SetCapture(hwnd);
      const POINT s = ScreenMousePos();
      ow->start = ScreenToMonitorLocal(s.x, s.y, ow->monitor_rect.left,
                                       ow->monitor_rect.top);
      ow->cur = ow->start;
      ow->dragging = true;
      ::InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    }
    case WM_MOUSEMOVE: {
      if (ow != nullptr && ow->dragging) {
        const POINT s = ScreenMousePos();
        ow->cur = ScreenToMonitorLocal(s.x, s.y, ow->monitor_rect.left,
                                       ow->monitor_rect.top);
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      if (ow == nullptr || !ow->dragging) {
        return 0;
      }
      ow->dragging = false;
      ::ReleaseCapture();
      const auto rect = ResolvePickedRect(ow->start.x, ow->start.y, ow->cur.x,
                                          ow->cur.y, ow->mon_w, ow->mon_h,
                                          kMinAreaSize);
      if (rect.has_value() && ow->session != nullptr) {
        PickedArea picked;
        picked.display_id = ow->display_id;
        picked.x = static_cast<std::int32_t>(rect->x);
        picked.y = static_cast<std::int32_t>(rect->y);
        picked.width = static_cast<std::int32_t>(rect->width);
        picked.height = static_cast<std::int32_t>(rect->height);
        ow->session->result = picked;
        ow->session->cancelled = false;
        ow->session->done = true;
      } else {
        // Too small / empty drag — treat as a cancel (matches macOS <5px).
        CancelSession(ow);
      }
      return 0;
    }
    case WM_RBUTTONDOWN:
      CancelSession(ow);
      return 0;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        CancelSession(ow);
      }
      return 0;
    case WM_SETCURSOR:
      ::SetCursor(::LoadCursorW(nullptr, IDC_CROSS));
      return TRUE;
    case WM_ERASEBKGND:
      return 1;  // fully handled in WM_PAINT (double-buffered).
    case WM_PAINT:
      PaintOverlay(hwnd, ow);
      return 0;
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, [] {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &OverlayWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_CROSS);
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

BOOL CALLBACK CollectMonitorProc(HMONITOR hmon, HDC /*hdc*/, LPRECT /*clip*/,
                                 LPARAM lparam) {
  auto* rects = reinterpret_cast<std::vector<RECT>*>(lparam);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (::GetMonitorInfoW(hmon, &mi) != 0) {
    rects->push_back(mi.rcMonitor);
  }
  return TRUE;
}

// Match a monitor's virtual-desktop origin to a display enumerator id (both are
// physical virtual-desktop pixels). Returns 0 when no record matches — the
// caller maps 0 to "primary" so a stale-config race still records.
std::int64_t DisplayIdForOrigin(
    const std::vector<clingfy::bridge::devices::DisplayRecord>& displays,
    LONG left, LONG top) {
  for (const auto& d : displays) {
    if (static_cast<LONG>(d.x) == left && static_cast<LONG>(d.y) == top) {
      return d.id;
    }
  }
  return 0;
}

}  // namespace

std::optional<PickedArea> PickArea() {
  // Re-entrancy guard: PickArea runs a nested message loop on the platform
  // thread, so a second pick dispatched mid-loop would stack a duplicate
  // overlay set. Refuse a concurrent pick; the caller treats nullopt as a
  // cancel. The guard releases when the outer pick returns.
  bool expected = false;
  if (!g_pick_in_progress.compare_exchange_strong(expected, true)) {
    return std::nullopt;
  }
  struct InProgressGuard {
    ~InProgressGuard() { g_pick_in_progress.store(false); }
  } in_progress_guard;

  EnsureClassRegistered();

  std::vector<RECT> monitor_rects;
  ::EnumDisplayMonitors(nullptr, nullptr, &CollectMonitorProc,
                        reinterpret_cast<LPARAM>(&monitor_rects));
  if (monitor_rects.empty()) {
    return std::nullopt;
  }

  const auto displays = clingfy::bridge::devices::EnumerateDisplays();
  const HINSTANCE hinst = ::GetModuleHandleW(nullptr);

  PickSession session;
  std::vector<HWND> windows;
  std::vector<OverlayWindow*> datas;
  windows.reserve(monitor_rects.size());
  datas.reserve(monitor_rects.size());

  for (const RECT& r : monitor_rects) {
    auto* ow = new OverlayWindow();
    ow->session = &session;
    ow->monitor_rect = r;
    ow->mon_w = static_cast<std::uint32_t>(r.right - r.left);
    ow->mon_h = static_cast<std::uint32_t>(r.bottom - r.top);
    ow->display_id = DisplayIdForOrigin(displays, r.left, r.top);

    HWND w = ::CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TOOLWINDOW, kWindowClassName,
        L"", WS_POPUP, r.left, r.top, static_cast<int>(ow->mon_w),
        static_cast<int>(ow->mon_h), nullptr, nullptr, hinst, ow);
    if (w == nullptr) {
      delete ow;
      continue;
    }
    ::SetLayeredWindowAttributes(w, 0, kBackdropAlpha, LWA_ALPHA);
    ::ShowWindow(w, SW_SHOWNOACTIVATE);
    windows.push_back(w);
    datas.push_back(ow);
  }

  if (windows.empty()) {
    for (auto* d : datas) {
      delete d;
    }
    return std::nullopt;
  }

  // Activate the first overlay so keyboard (Esc) is delivered. SW_SHOW (vs the
  // SW_SHOWNOACTIVATE the windows were created with) activates it;
  // SetForegroundWindow is best-effort (it can fail under the foreground lock).
  // Right-click cancel works on any window regardless of focus, so the loop
  // always has a usable exit even if focus isn't granted.
  ::ShowWindow(windows.front(), SW_SHOW);
  ::SetForegroundWindow(windows.front());
  ::SetFocus(windows.front());

  MSG msg{};
  while (!session.done) {
    const BOOL got = ::GetMessageW(&msg, nullptr, 0, 0);
    if (got == 0) {
      // WM_QUIT during the pick: re-post so the app's real loop still sees it,
      // and bail out as a cancel.
      ::PostQuitMessage(static_cast<int>(msg.wParam));
      session.cancelled = true;
      break;
    }
    if (got == -1) {
      session.cancelled = true;
      break;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  for (HWND w : windows) {
    ::DestroyWindow(w);
  }
  for (auto* d : datas) {
    ReleaseBackBuffer(d);
    delete d;
  }

  if (session.cancelled || !session.result.has_value()) {
    return std::nullopt;
  }
  return session.result;
}

}  // namespace clingfy::overlay
