#include "Capture/Indicator/recording_indicator_controller.h"

#include <algorithm>
#include <string>
#include <utility>

#include "Capture/Indicator/recording_indicator_model.h"

namespace clingfy::capture {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyRecordingIndicator";
constexpr UINT_PTR kTickTimerId = 1;
constexpr UINT kTickIntervalMs = 250;  // 4 Hz — keeps the seconds tick crisp.
constexpr UINT kMsgShow = WM_APP + 1;
constexpr UINT kMsgHide = WM_APP + 2;

// Logical (96-dpi) pill size. Wide enough for "00:00:00" plus the red dot.
constexpr int kBaseWidth = 132;
constexpr int kBaseHeight = 40;

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &RecordingIndicatorController::WndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

}  // namespace

RecordingIndicatorController& RecordingIndicatorController::Instance() {
  static RecordingIndicatorController instance;
  return instance;
}

RecordingIndicatorController::~RecordingIndicatorController() { Shutdown(); }

LRESULT CALLBACK RecordingIndicatorController::WndProc(HWND hwnd, UINT msg,
                                                       WPARAM wparam,
                                                       LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<RecordingIndicatorController*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case kMsgShow:
      if (self != nullptr) {
        self->PlaceWindow(hwnd);
      }
      ::ShowWindow(hwnd, SW_SHOWNA);  // show without stealing focus.
      ::InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    case kMsgHide:
      ::ShowWindow(hwnd, SW_HIDE);
      return 0;
    case WM_TIMER:
      if (wparam == kTickTimerId && self != nullptr &&
          self->visible_.load() && ::IsWindowVisible(hwnd)) {
        ::InvalidateRect(hwnd, nullptr, FALSE);
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

void RecordingIndicatorController::Paint(HWND hwnd) {
  PAINTSTRUCT ps{};
  HDC hdc = ::BeginPaint(hwnd, &ps);
  RECT client{};
  ::GetClientRect(hwnd, &client);
  const int cw = client.right - client.left;
  const int ch = client.bottom - client.top;
  if (cw <= 0 || ch <= 0) {
    ::EndPaint(hwnd, &ps);
    return;
  }

  // Pull the elapsed text off the provider (may take the engine lock).
  std::uint64_t seconds = 0;
  {
    std::lock_guard<std::mutex> lock(provider_mutex_);
    if (duration_provider_) {
      seconds = duration_provider_();
    }
  }
  const std::wstring text = [&] {
    const std::string ascii = FormatIndicatorElapsed(seconds);
    return std::wstring(ascii.begin(), ascii.end());  // ASCII-only, safe widen.
  }();

  // Double buffer so the pill + text land in one blit (no partial-frame tear,
  // same reason the camera overlay double-buffers).
  HDC mem = ::CreateCompatibleDC(hdc);
  HBITMAP buffer = ::CreateCompatibleBitmap(hdc, cw, ch);
  HGDIOBJ old_bmp = (mem != nullptr && buffer != nullptr)
                        ? ::SelectObject(mem, buffer)
                        : nullptr;
  HDC dc = (mem != nullptr && buffer != nullptr) ? mem : hdc;

  // Dark rounded pill background.
  RECT full{0, 0, cw, ch};
  HBRUSH bg = ::CreateSolidBrush(RGB(28, 28, 30));
  ::FillRect(dc, &full, bg);
  ::DeleteObject(bg);

  const int radius = std::min(ch, 20);
  HRGN rgn = ::CreateRoundRectRgn(0, 0, cw + 1, ch + 1, radius * 2, radius * 2);
  ::SetWindowRgn(hwnd, rgn, FALSE);  // window owns the region now.

  // Red "recording" dot on the left.
  const int dot = std::max(8, ch / 3);
  const int dot_x = std::max(6, ch / 4);
  const int dot_y = (ch - dot) / 2;
  HBRUSH red = ::CreateSolidBrush(RGB(255, 69, 58));
  HGDIOBJ old_brush = ::SelectObject(dc, red);
  HGDIOBJ old_pen = ::SelectObject(dc, ::GetStockObject(NULL_PEN));
  ::Ellipse(dc, dot_x, dot_y, dot_x + dot, dot_y + dot);
  ::SelectObject(dc, old_pen);
  ::SelectObject(dc, old_brush);
  ::DeleteObject(red);

  // Timer text.
  ::SetBkMode(dc, TRANSPARENT);
  ::SetTextColor(dc, RGB(245, 245, 247));
  HFONT font = ::CreateFontW(
      -std::max(12, ch / 2), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  HGDIOBJ old_font = font != nullptr ? ::SelectObject(dc, font) : nullptr;
  RECT text_rect{dot_x + dot + 8, 0, cw - 8, ch};
  ::DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &text_rect,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX);
  if (old_font != nullptr) {
    ::SelectObject(dc, old_font);
  }
  if (font != nullptr) {
    ::DeleteObject(font);
  }

  if (dc == mem) {
    ::BitBlt(hdc, 0, 0, cw, ch, mem, 0, 0, SRCCOPY);
    ::SelectObject(mem, old_bmp);
  }
  if (buffer != nullptr) {
    ::DeleteObject(buffer);
  }
  if (mem != nullptr) {
    ::DeleteDC(mem);
  }
  ::EndPaint(hwnd, &ps);
}

void RecordingIndicatorController::PlaceWindow(HWND hwnd) {
  RECT work{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
            ::GetSystemMetrics(SM_CYSCREEN)};
  if (HMONITOR mon = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
      mon != nullptr) {
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (::GetMonitorInfoW(mon, &mi) != 0) {
      work = mi.rcWork;
    }
  }
  const UINT dpi = ::GetDpiForWindow(hwnd);
  const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  const IndicatorRect r = ComputeIndicatorRect(
      work.left, work.top, work.right, work.bottom, scale, kBaseWidth,
      kBaseHeight);
  ::SetWindowPos(hwnd, HWND_TOPMOST, r.x, r.y, r.width, r.height,
                 SWP_NOACTIVATE);
}

bool RecordingIndicatorController::EnsureRunning() {
  if (running_.load()) {
    return true;
  }
  std::promise<bool> ready;
  std::future<bool> fut = ready.get_future();
  thread_ = std::thread(&RecordingIndicatorController::ThreadMain, this, &ready);
  const bool ok = fut.get();
  if (!ok && thread_.joinable()) {
    thread_.join();
  }
  return ok;
}

void RecordingIndicatorController::ThreadMain(std::promise<bool>* ready) {
  thread_id_ = ::GetCurrentThreadId();
  EnsureClassRegistered();

  // Opaque topmost tool window (NOT layered — same lesson as the camera
  // overlay: layered + region + display affinity rendered nothing on some
  // hybrid GPUs). Created HIDDEN; Show() reveals it.
  HWND hwnd = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName,
      L"Clingfy Recording", WS_POPUP, 0, 0, kBaseWidth, kBaseHeight, nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    ready->set_value(false);
    return;
  }

  // Never let the pill be burned into the recording.
  ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);

  hwnd_.store(hwnd);
  ::SetTimer(hwnd, kTickTimerId, kTickIntervalMs, nullptr);
  running_.store(true);
  ready->set_value(true);  // created HIDDEN — Show() reveals on demand.

  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  running_.store(false);
  hwnd_.store(nullptr);
  ::KillTimer(hwnd, kTickTimerId);
  ::DestroyWindow(hwnd);
}

void RecordingIndicatorController::Show(
    std::function<std::uint64_t()> duration_provider) {
  {
    std::lock_guard<std::mutex> lock(provider_mutex_);
    duration_provider_ = std::move(duration_provider);
  }
  if (!EnsureRunning()) {
    return;  // window creation failed — no indicator this session.
  }
  visible_.store(true);
  if (HWND hwnd = hwnd_.load(); hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgShow, 0, 0);
  }
}

void RecordingIndicatorController::Hide() {
  visible_.store(false);
  if (HWND hwnd = hwnd_.load(); hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgHide, 0, 0);
  }
}

void RecordingIndicatorController::Shutdown() {
  if (thread_.joinable()) {
    if (thread_id_ != 0) {
      ::PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
    }
    thread_.join();
  }
  running_.store(false);
  visible_.store(false);
  hwnd_.store(nullptr);
  thread_id_ = 0;
  std::lock_guard<std::mutex> lock(provider_mutex_);
  duration_provider_ = nullptr;
}

}  // namespace clingfy::capture
