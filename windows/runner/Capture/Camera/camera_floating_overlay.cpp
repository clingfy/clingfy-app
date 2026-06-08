#include "Capture/Camera/camera_floating_overlay.h"

#include <algorithm>
#include <cstdio>
#include <utility>

#include "Bridge/Devices/device_probe_log.h"

namespace clingfy::capture {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyCameraFloatingOverlay";
constexpr UINT_PTR kPaintTimerId = 1;
constexpr UINT kPaintIntervalMs = 33;  // ~30 fps repaint.
constexpr UINT kMsgShow = WM_APP + 1;
constexpr UINT kMsgHide = WM_APP + 2;

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &CameraFloatingOverlay::WndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_SIZEALL);  // hints "draggable".
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

}  // namespace

CameraFloatingOverlay::~CameraFloatingOverlay() { Stop(); }

LRESULT CALLBACK CameraFloatingOverlay::WndProc(HWND hwnd, UINT msg,
                                                WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<CameraFloatingOverlay*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_NCHITTEST:
      // The whole bubble is a drag handle — clicking anywhere moves it.
      return HTCAPTION;
    case kMsgShow:
      ::ShowWindow(hwnd, SW_SHOWNA);  // show without stealing focus.
      return 0;
    case kMsgHide:
      ::ShowWindow(hwnd, SW_HIDE);
      return 0;
    case WM_TIMER:
      if (wparam == kPaintTimerId && self != nullptr) {
        bool dirty = false;
        {
          std::lock_guard<std::mutex> lock(self->frame_mutex_);
          dirty = self->dirty_;
        }
        if (dirty && ::IsWindowVisible(hwnd)) {
          ::InvalidateRect(hwnd, nullptr, FALSE);
        }
      }
      return 0;
    case WM_PAINT:
      if (self != nullptr) {
        self->Paint(hwnd);
      } else {
        PAINTSTRUCT ps{};
        ::BeginPaint(hwnd, &ps);
        ::EndPaint(hwnd, &ps);
      }
      return 0;
    case WM_ERASEBKGND:
      return 1;
    default:
      return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
}

void CameraFloatingOverlay::Paint(HWND hwnd) {
  PAINTSTRUCT ps{};
  HDC hdc = ::BeginPaint(hwnd, &ps);
  RECT client{};
  ::GetClientRect(hwnd, &client);
  const int cw = client.right - client.left;
  const int ch = client.bottom - client.top;

  std::vector<std::uint8_t> frame;
  int fw = 0;
  int fh = 0;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (frame_w_ > 0 && frame_h_ > 0 &&
        frame_bgra_.size() >= static_cast<size_t>(frame_w_) * frame_h_ * 4) {
      frame = frame_bgra_;
      fw = frame_w_;
      fh = frame_h_;
    }
    dirty_ = false;
  }

  if (fw > 0 && fh > 0 && cw > 0 && ch > 0) {
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = fw;
    bmi.bmiHeader.biHeight = -fh;  // top-down.
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    ::SetStretchBltMode(hdc, HALFTONE);
    ::StretchDIBits(hdc, 0, 0, cw, ch, 0, 0, fw, fh, frame.data(), &bmi,
                    DIB_RGB_COLORS, SRCCOPY);
  } else {
    HBRUSH black = ::CreateSolidBrush(RGB(0, 0, 0));
    ::FillRect(hdc, &client, black);
    ::DeleteObject(black);
  }
  ::EndPaint(hwnd, &ps);
}

bool CameraFloatingOverlay::Start(const FloatingPlacement& placement) {
  if (running_.load()) {
    return true;
  }
  std::promise<bool> ready;
  std::future<bool> fut = ready.get_future();
  thread_ =
      std::thread(&CameraFloatingOverlay::ThreadMain, this, placement, &ready);
  const bool ok = fut.get();
  if (!ok && thread_.joinable()) {
    thread_.join();
  }
  return ok;
}

void CameraFloatingOverlay::ThreadMain(FloatingPlacement placement,
                                       std::promise<bool>* ready) {
  thread_id_ = ::GetCurrentThreadId();
  EnsureClassRegistered();

  // Opaque topmost tool window (NOT layered — layered + region + display
  // affinity rendered nothing on a hybrid GPU). Created HIDDEN; the engine
  // Shows it only when the user's mode is floating AND exclusion succeeded.
  HWND hwnd = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName,
      L"Clingfy Camera", WS_POPUP, placement.x, placement.y,
      std::max(1, placement.width), std::max(1, placement.height), nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    ready->set_value(false);
    return;
  }

  // Exclude from screen capture so the floating bubble is never burned into
  // screen.mov. Record whether it succeeded — the engine refuses to Show() the
  // bubble when it did not (that would double the camera at export).
  const BOOL excluded =
      ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  wda_excluded_.store(excluded != 0);
  {
    char b[128];
    std::snprintf(b, sizeof(b),
                  "CameraFloatingOverlay: window created at (%d,%d) %dx%d "
                  "wdaExcluded=%d",
                  placement.x, placement.y, placement.width, placement.height,
                  excluded ? 1 : 0);
    clingfy::bridge::devices::LogDeviceProbe(b);
  }

  if (placement.rounded) {
    const int radius =
        std::max(2, std::min(placement.width, placement.height) / 6);
    HRGN rgn = ::CreateRoundRectRgn(0, 0, placement.width + 1,
                                    placement.height + 1, radius, radius);
    if (rgn != nullptr) {
      ::SetWindowRgn(hwnd, rgn, TRUE);  // window owns the region.
    }
  }

  hwnd_.store(hwnd);
  ::SetTimer(hwnd, kPaintTimerId, kPaintIntervalMs, nullptr);
  running_.store(true);
  ready->set_value(true);  // created HIDDEN — engine Show()s on demand.

  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  running_.store(false);
  hwnd_.store(nullptr);
  ::KillTimer(hwnd, kPaintTimerId);
  ::DestroyWindow(hwnd);
}

void CameraFloatingOverlay::Show() {
  HWND hwnd = hwnd_.load();
  if (hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgShow, 0, 0);
  }
}

void CameraFloatingOverlay::Hide() {
  HWND hwnd = hwnd_.load();
  if (hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgHide, 0, 0);
  }
}

void CameraFloatingOverlay::PublishBgra(const std::uint8_t* bgra, int width,
                                        int height) {
  if (!running_.load() || bgra == nullptr || width <= 0 || height <= 0) {
    return;
  }
  std::lock_guard<std::mutex> lock(frame_mutex_);
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  frame_bgra_.assign(bgra, bgra + bytes);
  frame_w_ = width;
  frame_h_ = height;
  dirty_ = true;
}

void CameraFloatingOverlay::Stop() {
  if (thread_.joinable()) {
    if (thread_id_ != 0) {
      ::PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
    }
    thread_.join();
  }
  running_.store(false);
  hwnd_.store(nullptr);
  thread_id_ = 0;
}

}  // namespace clingfy::capture
