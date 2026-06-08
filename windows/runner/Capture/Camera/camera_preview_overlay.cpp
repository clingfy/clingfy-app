#include "Capture/Camera/camera_preview_overlay.h"

#include <algorithm>
#include <cstdio>
#include <utility>

#include "Bridge/Devices/device_probe_log.h"

namespace clingfy::capture {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyCameraPreviewOverlay";
constexpr UINT_PTR kPaintTimerId = 1;
constexpr UINT kPaintIntervalMs = 33;  // ~30 fps repaint.

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &CameraPreviewOverlay::WndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;  // we paint every pixel ourselves.
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

}  // namespace

CameraPreviewOverlay::~CameraPreviewOverlay() { Stop(); }

LRESULT CALLBACK CameraPreviewOverlay::WndProc(HWND hwnd, UINT msg,
                                               WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<CameraPreviewOverlay*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_TIMER:
      if (wparam == kPaintTimerId && self != nullptr) {
        bool dirty = false;
        {
          std::lock_guard<std::mutex> lock(self->frame_mutex_);
          dirty = self->dirty_;
        }
        if (dirty) {
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
      return 1;  // no flicker — WM_PAINT fills the whole client.
    default:
      return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
}

void CameraPreviewOverlay::Paint(HWND hwnd) {
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
        frame_bgra_.size() >=
            static_cast<size_t>(frame_w_) * frame_h_ * 4) {
      frame = frame_bgra_;  // copy out, then release the lock for the blit.
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
    // No frame yet — paint the bubble black so it reads as "starting".
    HBRUSH black = ::CreateSolidBrush(RGB(0, 0, 0));
    ::FillRect(hdc, &client, black);
    ::DeleteObject(black);
  }
  ::EndPaint(hwnd, &ps);
}

bool CameraPreviewOverlay::Start(const BubblePlacement& placement) {
  if (running_.load()) {
    return true;
  }
  std::promise<bool> ready;
  std::future<bool> fut = ready.get_future();
  thread_ = std::thread(&CameraPreviewOverlay::ThreadMain, this, placement,
                        &ready);
  const bool ok = fut.get();
  if (!ok && thread_.joinable()) {
    thread_.join();
  }
  return ok;
}

void CameraPreviewOverlay::ThreadMain(BubblePlacement placement,
                                      std::promise<bool>* ready) {
  thread_id_ = ::GetCurrentThreadId();
  EnsureClassRegistered();

  // A plain opaque topmost tool window — NOT layered. The bubble is opaque
  // video, so it needs no per-pixel alpha; a layered window plus SetWindowRgn
  // plus display-affinity is a fragile combo that rendered nothing on at least
  // one hybrid-GPU laptop (the bubble's window was created but never visible).
  // Shape comes from SetWindowRgn below; content from WM_PAINT/StretchDIBits.
  HWND hwnd = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName,
      L"Clingfy Camera", WS_POPUP, placement.x, placement.y,
      std::max(1, placement.width), std::max(1, placement.height), nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    ready->set_value(false);
    return;
  }

  // Exclude the bubble from screen capture so it is visible to the USER but NOT
  // burned into the recorded screen video (the camera is composited from
  // raw.mov at export — a captured preview would double it up). Best-effort:
  // WDA_EXCLUDEFROMCAPTURE needs Windows 10 2004+. Log the result so an
  // invisible-bubble report can tell whether the affinity call is implicated.
  const BOOL excluded =
      ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  {
    char b[128];
    std::snprintf(b, sizeof(b),
                  "CameraPreviewOverlay: window created at (%d,%d) %dx%d "
                  "excludeFromCapture=%d",
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
      // The window owns the region after SetWindowRgn — do not delete it.
      ::SetWindowRgn(hwnd, rgn, TRUE);
    }
  }

  ::ShowWindow(hwnd, SW_SHOWNA);  // show without activating / stealing focus.
  ::SetTimer(hwnd, kPaintTimerId, kPaintIntervalMs, nullptr);
  running_.store(true);
  ready->set_value(true);

  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  running_.store(false);
  ::KillTimer(hwnd, kPaintTimerId);
  ::DestroyWindow(hwnd);
}

void CameraPreviewOverlay::PublishBgra(const std::uint8_t* bgra, int width,
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

void CameraPreviewOverlay::Stop() {
  if (thread_.joinable()) {
    // Break the message loop on the overlay thread; it destroys the window.
    if (thread_id_ != 0) {
      ::PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
    }
    thread_.join();
  }
  running_.store(false);
  thread_id_ = 0;
}

}  // namespace clingfy::capture
