#include "Capture/Camera/camera_floating_overlay.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <utility>
#include <vector>

#include "Bridge/Devices/device_probe_log.h"
#include "Capture/Camera/camera_overlay_style_store.h"

namespace clingfy::capture {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyCameraFloatingOverlay";
constexpr UINT_PTR kPaintTimerId = 1;
constexpr UINT kPaintIntervalMs = 33;  // ~30 fps repaint.
constexpr UINT kMsgShow = WM_APP + 1;
constexpr UINT kMsgHide = WM_APP + 2;
constexpr double kPi = 3.14159265358979323846;

// A regular polygon (hexagon) / star region inscribed in the shortest window
// dimension, centered. `sides` vertices for the polygon; the star uses
// `sides` points (2*sides vertices) alternating outer/inner radius.
HRGN BuildPolygonRegion(int w, int h, int sides, double rotation,
                        double inner_ratio, bool star) {
  const double cx = w / 2.0;
  const double cy = h / 2.0;
  const double radius = std::min(w, h) / 2.0;
  std::vector<POINT> pts;
  const int vertices = star ? sides * 2 : sides;
  pts.reserve(vertices);
  for (int i = 0; i < vertices; ++i) {
    const double r =
        star ? ((i % 2 == 0) ? radius : radius * inner_ratio) : radius;
    const double angle =
        rotation + (2.0 * kPi * i / vertices) - kPi / 2.0;
    pts.push_back(POINT{static_cast<LONG>(std::lround(cx + r * std::cos(angle))),
                        static_cast<LONG>(std::lround(cy + r * std::sin(angle)))});
  }
  return ::CreatePolygonRgn(pts.data(), static_cast<int>(pts.size()), WINDING);
}

// Build the window region for an OverlayShape.wireValue. Mirrors the Dart
// in-app clipper (camera_overlay_bubble.dart) so the floating bubble and the
// in-app preview agree on the silhouette. Caller owns the returned HRGN.
//
// The compact shapes (circle / square / hexagon / star) are inscribed in a
// CENTERED SQUARE of the window so a circle reads as a real circle and a square
// as a real square — not stretched to the window's 16:9 aspect. The window
// content fills the full frame; the region crops it to the centered shape (the
// same center-crop the in-app FittedBox cover does). roundedRect / squircle are
// deliberately full-window "rectangle" silhouettes.
HRGN BuildShapeRegion(int w, int h, int shape_wire, double roundness) {
  const int shortest = std::min(w, h);
  const clingfy::capture::InscribedSquare sq =
      clingfy::capture::CameraOverlayInscribedSquare(w, h);
  const int sq_rr =
      static_cast<int>(std::clamp(roundness, 0.0, 0.4) * sq.side);
  switch (shape_wire) {
    case 0:  // circle — true centered circle
      return ::CreateEllipticRgn(sq.x, sq.y, sq.x + sq.side + 1,
                                 sq.y + sq.side + 1);
    case 2:  // square — centered square (rounded corners via roundness)
      return ::CreateRoundRectRgn(sq.x, sq.y, sq.x + sq.side + 1,
                                  sq.y + sq.side + 1, 2 * sq_rr, 2 * sq_rr);
    case 1: {  // roundedRect — full-window rounded rectangle
      const int rr =
          static_cast<int>(std::clamp(roundness, 0.0, 0.4) * shortest);
      return ::CreateRoundRectRgn(0, 0, w + 1, h + 1, 2 * rr, 2 * rr);
    }
    case 3:  // hexagon — centered regular polygon
      return BuildPolygonRegion(w, h, 6, kPi / 6.0, 0.0, /*star=*/false);
    case 4:  // star — centered
      return BuildPolygonRegion(w, h, 5, 0.0, 0.5, /*star=*/true);
    case 5:  // squircle ≈ strongly-rounded full-window rect (painter fallback)
    default: {
      const int r = static_cast<int>(0.32 * shortest);
      return ::CreateRoundRectRgn(0, 0, w + 1, h + 1, 2 * r, 2 * r);
    }
  }
}

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
        // Pick up live style changes (shape / mirror / border) each tick.
        self->SyncStyleFromStore(hwnd);
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
    // Mirror horizontally by flipping the destination width (selfie view — the
    // Dart overlay mirror default). The window region clips to the shape.
    if (style_mirror_) {
      ::StretchDIBits(hdc, cw, 0, -cw, ch, 0, 0, fw, fh, frame.data(), &bmi,
                      DIB_RGB_COLORS, SRCCOPY);
    } else {
      ::StretchDIBits(hdc, 0, 0, cw, ch, 0, 0, fw, fh, frame.data(), &bmi,
                      DIB_RGB_COLORS, SRCCOPY);
    }

    // Border: stroke the shape outline with the overlay border color. FrameRgn
    // follows any region shape (circle / rounded / polygon), so it works for
    // every OverlayShape. Opacity / shadow / chroma are export-only here.
    if (style_has_border_ && style_border_px_ > 0.0f) {
      HRGN border_rgn =
          BuildShapeRegion(cw, ch, style_shape_wire_, style_roundness_);
      if (border_rgn != nullptr) {
        const std::uint32_t a = (style_border_argb_ >> 24) & 0xFF;
        const COLORREF rgb =
            RGB((style_border_argb_ >> 16) & 0xFF,
                (style_border_argb_ >> 8) & 0xFF, style_border_argb_ & 0xFF);
        if (a > 0) {
          HBRUSH brush = ::CreateSolidBrush(rgb);
          if (brush != nullptr) {
            const int bw = std::max(1, static_cast<int>(style_border_px_));
            ::FrameRgn(hdc, border_rgn, brush, bw, bw);
            ::DeleteObject(brush);
          }
        }
        ::DeleteObject(border_rgn);
      }
    }
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

  hwnd_.store(hwnd);
  // Apply the current overlay style (shape region / mirror / border) up front so
  // the bubble is correctly shaped the instant it is Shown, not one tick later.
  SyncStyleFromStore(hwnd);
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

void CameraFloatingOverlay::SyncStyleFromStore(HWND hwnd) {
  auto& store = CameraOverlayStyleStore::Instance();
  const std::uint64_t rev = store.revision();
  if (rev == last_style_revision_) {
    return;  // nothing changed since the last tick.
  }
  last_style_revision_ = rev;

  const CameraOverlayLiveStyle s = store.Snapshot();
  const ResolvedBubbleStyle resolved = ResolveOverlayBubbleStyle(s);
  style_shape_wire_ = s.shape_wire;
  style_roundness_ = s.roundness;
  style_mirror_ = s.mirror;
  style_has_border_ =
      resolved.style.has_border_color && resolved.style.border_width > 0.0;
  style_border_argb_ = resolved.style.border_argb;
  style_border_px_ = static_cast<float>(resolved.style.border_width);

  RECT client{};
  ::GetClientRect(hwnd, &client);
  const int w = client.right - client.left;
  const int h = client.bottom - client.top;
  if (w > 0 && h > 0) {
    HRGN rgn = BuildShapeRegion(w, h, style_shape_wire_, style_roundness_);
    // SetWindowRgn takes ownership of rgn; passing TRUE repaints the frame.
    ::SetWindowRgn(hwnd, rgn, TRUE);
  }
  ::InvalidateRect(hwnd, nullptr, FALSE);
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
