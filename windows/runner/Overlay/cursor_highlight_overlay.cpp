#include "Overlay/cursor_highlight_overlay.h"

#include <shellscalingapi.h>

#include <cstring>

namespace clingfy::overlay {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyCursorHighlight";
constexpr UINT_PTR kTickTimerId = 1;
constexpr UINT kTickIntervalMs = 16;  // ~60 Hz: follows the pointer smoothly.
constexpr UINT kMsgShow = WM_APP + 1;
constexpr UINT kMsgHide = WM_APP + 2;

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &CursorHighlightOverlay::WndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

unsigned DpiAt(POINT p) {
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  const HMONITOR monitor = ::MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr ||
      FAILED(::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    return 96;
  }
  return dpi_x;
}

// The LOGICAL left button. GetAsyncKeyState reads physical buttons, so with
// the buttons swapped the primary click is VK_RBUTTON.
bool PrimaryButtonDown() {
  const int vk = ::GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
  return (::GetAsyncKeyState(vk) & 0x8000) != 0;
}

}  // namespace

CursorHighlightOverlay& CursorHighlightOverlay::Instance() {
  static CursorHighlightOverlay instance;
  return instance;
}

CursorHighlightOverlay::~CursorHighlightOverlay() { Shutdown(); }

LRESULT CALLBACK CursorHighlightOverlay::WndProc(HWND hwnd, UINT msg,
                                                WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<CursorHighlightOverlay*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    switch (msg) {
      case kMsgShow:
        self->OnShow(hwnd);
        return 0;
      case kMsgHide:
        self->OnHide(hwnd);
        return 0;
      case WM_TIMER:
        if (wparam == kTickTimerId) {
          self->OnTick(hwnd);
          return 0;
        }
        break;
      case WM_NCHITTEST:
        return HTTRANSPARENT;  // never in the way of a click
      default:
        break;
    }
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

void CursorHighlightOverlay::SetEnabled(bool enabled) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    enabled_ = enabled;
  }
  Reconcile();
}

void CursorHighlightOverlay::SetLinkedToRecording(bool linked) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    linked_ = linked;
  }
  Reconcile();
}

void CursorHighlightOverlay::SetRecordingState(bool actively_recording,
                                               bool session_disabled) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    actively_recording_ = actively_recording;
    session_disabled_ = session_disabled;
  }
  Reconcile();
}

void CursorHighlightOverlay::ClearRecordingState() {
  SetRecordingState(false, false);
}

bool CursorHighlightOverlay::WantsShowForTesting() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return CursorHighlightShouldShow(enabled_, linked_, actively_recording_,
                                   session_disabled_);
}

void CursorHighlightOverlay::Reconcile() {
  const bool want = WantsShowForTesting();
  if (want) {
    if (!EnsureRunning()) {
      return;  // no window this time; the next toggle retries
    }
    ::PostMessageW(hwnd_.load(), kMsgShow, 0, 0);
  } else if (HWND hwnd = hwnd_.load(); hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgHide, 0, 0);
  }
}

bool CursorHighlightOverlay::EnsureRunning() {
  // Callers are the platform thread (Dart setters) and the engine (under its
  // lock, also on the platform thread), so creation is never contended.
  if (hwnd_.load() != nullptr) {
    return true;
  }
  if (thread_.joinable()) {
    return false;  // a previous start failed and is being torn down
  }
  std::promise<bool> ready;
  std::future<bool> fut = ready.get_future();
  thread_ = std::thread(&CursorHighlightOverlay::ThreadMain, this, &ready);
  const bool ok = fut.get();
  if (!ok && thread_.joinable()) {
    thread_.join();
  }
  return ok;
}

void CursorHighlightOverlay::ThreadMain(std::promise<bool>* ready) {
  thread_id_ = ::GetCurrentThreadId();
  EnsureClassRegistered();
  // Layered for per-pixel alpha (the disc is 25% yellow), transparent to
  // input, never activated, kept out of Alt+Tab. Deliberately NOT given a
  // display affinity: the highlight is meant to be recorded (macOS parity).
  HWND hwnd = ::CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kWindowClassName, L"Clingfy Cursor Highlight", WS_POPUP, 0, 0, 1, 1,
      nullptr, nullptr, ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    ready->set_value(false);
    return;
  }
  hwnd_.store(hwnd);
  ready->set_value(true);

  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }
  ::KillTimer(hwnd, kTickTimerId);
  hwnd_.store(nullptr);
  shown_.store(false);
  ::DestroyWindow(hwnd);
}

void CursorHighlightOverlay::OnShow(HWND hwnd) {
  if (shown_.load()) {
    return;
  }
  POINT cursor{};
  ::GetCursorPos(&cursor);
  dpi_ = 0;  // force a size + raster for the current monitor
  has_click_ = false;
  button_was_down_ = PrimaryButtonDown();
  Present(hwnd, cursor, /*redraw=*/true);
  ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  ::SetTimer(hwnd, kTickTimerId, kTickIntervalMs, nullptr);
  shown_.store(true);
}

void CursorHighlightOverlay::OnHide(HWND hwnd) {
  ::KillTimer(hwnd, kTickTimerId);
  ::ShowWindow(hwnd, SW_HIDE);
  shown_.store(false);
}

void CursorHighlightOverlay::OnTick(HWND hwnd) {
  POINT cursor{};
  if (!::GetCursorPos(&cursor)) {
    return;  // e.g. the secure desktop; try again next tick
  }
  const bool down = PrimaryButtonDown();
  if (down && !button_was_down_) {
    click_at_ = std::chrono::steady_clock::now();
    has_click_ = true;
  }
  button_was_down_ = down;
  // Redraw only while a pulse runs, plus once after it ends to clear it.
  const bool pulsing =
      has_click_ &&
      std::chrono::duration<double>(std::chrono::steady_clock::now() -
                                    click_at_)
              .count() < kCursorHighlightPulseSeconds;
  const bool redraw = pulsing || pulse_drawn_;
  if (redraw || cursor.x != last_cursor_.x || cursor.y != last_cursor_.y) {
    Present(hwnd, cursor, redraw);
  }
}

void CursorHighlightOverlay::Present(HWND hwnd, POINT cursor, bool redraw) {
  const unsigned dpi = DpiAt(cursor);
  if (dpi != dpi_) {
    dpi_ = dpi;
    size_px_ = CursorHighlightWindowPx(dpi);
    redraw = true;  // a new monitor scale: new size, new pixels
  }
  last_cursor_ = cursor;
  const POINT origin{cursor.x - size_px_ / 2, cursor.y - size_px_ / 2};
  if (!redraw) {
    ::SetWindowPos(hwnd, HWND_TOPMOST, origin.x, origin.y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE);
    return;
  }

  const double since =
      has_click_ ? std::chrono::duration<double>(
                       std::chrono::steady_clock::now() - click_at_)
                       .count()
                 : -1.0;
  const CursorHighlightPulse pulse = CursorHighlightPulseAt(since);
  pulse_drawn_ = pulse.active;
  RasterizeCursorHighlight(&pixels_, size_px_, dpi_ / 96.0, pulse);

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = size_px_;
  bmi.bmiHeader.biHeight = -size_px_;  // top-down, as rasterized
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  HDC screen = ::GetDC(nullptr);
  HDC mem = ::CreateCompatibleDC(screen);
  void* bits = nullptr;
  HBITMAP dib =
      ::CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (dib != nullptr && bits != nullptr) {
    std::memcpy(bits, pixels_.data(), pixels_.size() * sizeof(std::uint32_t));
    HGDIOBJ old = ::SelectObject(mem, dib);
    POINT src{0, 0};
    SIZE size{size_px_, size_px_};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    POINT dst = origin;
    ::UpdateLayeredWindow(hwnd, screen, &dst, &size, mem, &src, 0, &blend,
                          ULW_ALPHA);
    ::SelectObject(mem, old);
  }
  if (dib != nullptr) {
    ::DeleteObject(dib);
  }
  ::DeleteDC(mem);
  ::ReleaseDC(nullptr, screen);
}

void CursorHighlightOverlay::Shutdown() {
  if (thread_.joinable()) {
    if (thread_id_ != 0) {
      ::PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
    }
    thread_.join();
  }
  thread_id_ = 0;
  hwnd_.store(nullptr);
  shown_.store(false);
}

}  // namespace clingfy::overlay
