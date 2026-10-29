#include "Overlay/area_reveal_overlay.h"

#include <shellscalingapi.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>

#include "Bridge/Devices/display_enumerator.h"
#include "Capture/windows_selection_state.h"

namespace clingfy::overlay {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyAreaReveal";
constexpr UINT_PTR kHideTimerId = 1;

// Platform thread only, like every caller.
HWND g_window = nullptr;
bool g_shown = false;
RECT g_rect{};

LRESULT CALLBACK RevealWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                               LPARAM lparam) {
  switch (msg) {
    case WM_TIMER:
      if (wparam == kHideTimerId) {
        HideAreaReveal();
        return 0;
      }
      break;
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

HWND EnsureWindow() {
  if (g_window != nullptr) {
    return g_window;
  }
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &RevealWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
  g_window = ::CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kWindowClassName, L"Clingfy Area", WS_POPUP, 0, 0, 1, 1, nullptr,
      nullptr, ::GetModuleHandleW(nullptr), nullptr);
  return g_window;
}

void Present(HWND hwnd, const AreaRevealFrame& frame) {
  const int w = frame.window.right - frame.window.left;
  const int h = frame.window.bottom - frame.window.top;
  std::vector<std::uint32_t> pixels;
  RasterizeAreaRevealFrame(&pixels, w, h, frame.line_px);

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = w;
  bmi.bmiHeader.biHeight = -h;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  HDC screen = ::GetDC(nullptr);
  HDC mem = ::CreateCompatibleDC(screen);
  void* bits = nullptr;
  HBITMAP dib =
      ::CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (dib != nullptr && bits != nullptr) {
    std::memcpy(bits, pixels.data(), pixels.size() * sizeof(std::uint32_t));
    HGDIOBJ old = ::SelectObject(mem, dib);
    POINT src{0, 0};
    POINT dst{frame.window.left, frame.window.top};
    SIZE size{w, h};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
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

}  // namespace

AreaRevealFrame ComputeAreaRevealFrame(const RECT& monitor, std::int32_t x,
                                       std::int32_t y, std::int32_t width,
                                       std::int32_t height, unsigned dpi) {
  AreaRevealFrame frame;
  const double scale = (dpi == 0 ? 96.0 : static_cast<double>(dpi)) / 96.0;
  frame.line_px =
      std::max(1, static_cast<int>(std::lround(kAreaRevealLineDip * scale)));
  const int outer = frame.line_px / 2;

  // The area on screen, clamped to its monitor (Start clamps it the same way).
  const LONG left = std::max<LONG>(monitor.left, monitor.left + x);
  const LONG top = std::max<LONG>(monitor.top, monitor.top + y);
  const LONG right = std::min<LONG>(monitor.right, monitor.left + x + width);
  const LONG bottom = std::min<LONG>(monitor.bottom, monitor.top + y + height);
  if (right <= left || bottom <= top) {
    return frame;  // nothing of it is on this monitor
  }
  frame.window.left = std::max<LONG>(monitor.left, left - outer);
  frame.window.top = std::max<LONG>(monitor.top, top - outer);
  frame.window.right = std::min<LONG>(monitor.right, right + outer);
  frame.window.bottom = std::min<LONG>(monitor.bottom, bottom + outer);
  return frame;
}

void RasterizeAreaRevealFrame(std::vector<std::uint32_t>* bgra, int width,
                              int height, int line_px) {
  bgra->assign(static_cast<std::size_t>(std::max(width, 0)) *
                   static_cast<std::size_t>(std::max(height, 0)),
               0u);
  for (int yy = 0; yy < height; ++yy) {
    const bool edge_row = yy < line_px || yy >= height - line_px;
    for (int xx = 0; xx < width; ++xx) {
      if (edge_row || xx < line_px || xx >= width - line_px) {
        (*bgra)[static_cast<std::size_t>(yy) * width + xx] = 0xFFFFFFFFu;
      }
    }
  }
}

void ShowAreaReveal() {
  const auto region =
      clingfy::capture::WindowsSelectionState::Instance().CurrentAreaRegion();
  if (!region.has_value()) {
    return;  // macOS: no area selected, nothing to reveal
  }
  const auto monitor =
      clingfy::bridge::devices::ResolveHMonitor(region->display_id);
  if (!monitor.has_value()) {
    return;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(*monitor, &info)) {
    return;
  }
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  if (FAILED(::GetDpiForMonitor(*monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    dpi_x = 96;
  }
  const AreaRevealFrame frame =
      ComputeAreaRevealFrame(info.rcMonitor, region->x, region->y,
                             region->width, region->height, dpi_x);
  if (frame.window.right <= frame.window.left ||
      frame.window.bottom <= frame.window.top) {
    return;
  }
  HWND hwnd = EnsureWindow();
  if (hwnd == nullptr) {
    return;
  }
  Present(hwnd, frame);
  ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  // Replaces any running timer, so a second reveal gets its full second.
  ::SetTimer(hwnd, kHideTimerId, kAreaRevealAutoHideMs, nullptr);
  g_shown = true;
  g_rect = frame.window;
}

void HideAreaReveal() {
  if (g_window == nullptr) {
    return;
  }
  ::KillTimer(g_window, kHideTimerId);
  ::ShowWindow(g_window, SW_HIDE);
  g_shown = false;
}

bool IsAreaRevealShownForTesting() { return g_shown; }
RECT AreaRevealWindowRectForTesting() { return g_rect; }

}  // namespace clingfy::overlay
