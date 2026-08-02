#include "Capture/PreRecordingBar/pre_recording_bar_popover.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <utility>

#include "Capture/PreRecordingBar/pre_recording_bar_popover_model.h"

namespace clingfy::capture {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyBarPickerPopover";

// Logical (96-dpi) metrics; scaled by DPI at Show time.
constexpr int kRowHeightLogical = 30;
constexpr int kVPadLogical = 6;
constexpr int kHPadLogical = 14;
constexpr int kCheckColLogical = 22;  // leading column for the selected tick.
constexpr int kMinWidthLogical = 160;
constexpr int kMaxWidthLogical = 420;
constexpr int kAnchorGapLogical = 6;

constexpr COLORREF kBg = RGB(38, 38, 42);
constexpr COLORREF kHoverBg = RGB(58, 58, 64);
constexpr COLORREF kText = RGB(235, 235, 237);
constexpr COLORREF kSelectedText = RGB(64, 156, 255);

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &PreRecordingBarPopover::WndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

RECT WorkAreaForAnchor(const RECT& anchor) {
  RECT work{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
            ::GetSystemMetrics(SM_CYSCREEN)};
  if (HMONITOR mon = ::MonitorFromRect(&anchor, MONITOR_DEFAULTTOPRIMARY);
      mon != nullptr) {
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (::GetMonitorInfoW(mon, &mi) != 0) {
      work = mi.rcWork;
    }
  }
  return work;
}

}  // namespace

PreRecordingBarPopover::~PreRecordingBarPopover() { Destroy(); }

LRESULT CALLBACK PreRecordingBarPopover::WndProc(HWND hwnd, UINT msg,
                                                 WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<PreRecordingBarPopover*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_MOUSEMOVE:
      if (self != nullptr) {
        self->OnMouseMove(hwnd, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      }
      return 0;
    case WM_LBUTTONDOWN:
      // Under SetCapture, lparam is client-relative even for clicks outside.
      if (self != nullptr) {
        self->OnClick(hwnd, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      }
      return 0;
    case WM_CAPTURECHANGED:
      // Lost capture to another window — treat as a dismiss.
      if (self != nullptr && self->visible_) {
        self->Hide();
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

bool PreRecordingBarPopover::EnsureWindow() {
  if (hwnd_ != nullptr) {
    return true;
  }
  EnsureClassRegistered();
  HWND hwnd = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName,
      L"Clingfy Picker", WS_POPUP, 0, 0, 10, 10, nullptr, nullptr,
      ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    return false;
  }
  ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  hwnd_ = hwnd;
  return true;
}

void PreRecordingBarPopover::Show(const std::vector<Row>& rows,
                                  const RECT& anchor,
                                  std::function<void(int)> on_pick) {
  if (rows.empty() || !EnsureWindow()) {
    return;
  }
  rows_ = rows;
  on_pick_ = std::move(on_pick);
  hovered_ = -1;
  for (int i = 0; i < static_cast<int>(rows_.size()); ++i) {
    if (rows_[i].selected) {
      hovered_ = i;  // start the highlight on the current selection.
      break;
    }
  }

  const UINT dpi = ::GetDpiForWindow(hwnd_);
  const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  const auto px = [scale](int logical) {
    return std::max(1, static_cast<int>(std::lround(logical * scale)));
  };
  row_height_ = px(kRowHeightLogical);
  vpad_ = px(kVPadLogical);

  // Measure the widest label so the popover fits its content (clamped).
  int text_w = 0;
  if (HDC dc = ::GetDC(hwnd_); dc != nullptr) {
    HFONT font = ::CreateFontW(
        -std::max(11, row_height_ / 2), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HGDIOBJ old = font != nullptr ? ::SelectObject(dc, font) : nullptr;
    for (const Row& r : rows_) {
      SIZE s{};
      if (::GetTextExtentPoint32W(dc, r.label.c_str(),
                                  static_cast<int>(r.label.size()), &s) != 0) {
        text_w = std::max(text_w, static_cast<int>(s.cx));
      }
    }
    if (old != nullptr) {
      ::SelectObject(dc, old);
    }
    if (font != nullptr) {
      ::DeleteObject(font);
    }
    ::ReleaseDC(hwnd_, dc);
  }
  width_ = std::clamp(text_w + px(kCheckColLogical) + 2 * px(kHPadLogical),
                      px(kMinWidthLogical), px(kMaxWidthLogical));

  Position(hwnd_, anchor);
  ::ShowWindow(hwnd_, SW_SHOWNA);
  ::SetCapture(hwnd_);  // route outside clicks here so we can dismiss.
  visible_ = true;
  ::InvalidateRect(hwnd_, nullptr, FALSE);
}

void PreRecordingBarPopover::Position(HWND hwnd, const RECT& anchor) {
  const int count = static_cast<int>(rows_.size());
  const PopoverLayout layout =
      ComputePopoverLayout(count, width_, row_height_, vpad_);
  const RECT work = WorkAreaForAnchor(anchor);
  const UINT dpi = ::GetDpiForWindow(hwnd);
  const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  const int gap = std::max(1, static_cast<int>(std::lround(kAnchorGapLogical *
                                                           scale)));

  int x = static_cast<int>(anchor.left);
  int y = static_cast<int>(anchor.top) - layout.height - gap;  // above.
  if (y < work.top) {
    y = static_cast<int>(anchor.bottom) + gap;  // no room above -> below.
  }
  x = std::clamp(x, static_cast<int>(work.left),
                 std::max(static_cast<int>(work.left),
                          static_cast<int>(work.right) - width_));
  y = std::clamp(y, static_cast<int>(work.top),
                 std::max(static_cast<int>(work.top),
                          static_cast<int>(work.bottom) - layout.height));
  ::SetWindowPos(hwnd, HWND_TOPMOST, x, y, width_, layout.height,
                 SWP_NOACTIVATE);
}

void PreRecordingBarPopover::OnMouseMove(HWND hwnd, int client_x,
                                         int client_y) {
  const PopoverLayout layout = ComputePopoverLayout(
      static_cast<int>(rows_.size()), width_, row_height_, vpad_);
  const int hit = HitTestPopoverRow(layout, client_x, client_y);
  if (hit != hovered_) {
    hovered_ = hit;
    ::InvalidateRect(hwnd, nullptr, FALSE);
  }
}

void PreRecordingBarPopover::OnClick(HWND hwnd, int client_x, int client_y) {
  const PopoverLayout layout = ComputePopoverLayout(
      static_cast<int>(rows_.size()), width_, row_height_, vpad_);
  const bool inside = client_x >= 0 && client_x < width_ && client_y >= 0 &&
                      client_y < layout.height;
  if (!inside) {
    Hide();  // click outside dismisses.
    return;
  }
  const int row = HitTestPopoverRow(layout, client_x, client_y);
  // Copy the callback before Hide() clears it, then fire after the popover is
  // down so the emit + any re-show happen against a clean state.
  std::function<void(int)> cb = on_pick_;
  Hide();
  if (row >= 0 && cb) {
    cb(row);
  }
}

void PreRecordingBarPopover::Paint(HWND hwnd) {
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

  HDC mem = ::CreateCompatibleDC(hdc);
  HBITMAP buffer = ::CreateCompatibleBitmap(hdc, cw, ch);
  HGDIOBJ old_bmp = (mem != nullptr && buffer != nullptr)
                        ? ::SelectObject(mem, buffer)
                        : nullptr;
  HDC dc = (mem != nullptr && buffer != nullptr) ? mem : hdc;

  RECT full{0, 0, cw, ch};
  HBRUSH bg = ::CreateSolidBrush(kBg);
  ::FillRect(dc, &full, bg);
  ::DeleteObject(bg);
  const int radius = std::max(2, vpad_);
  HRGN rgn = ::CreateRoundRectRgn(0, 0, cw + 1, ch + 1, radius * 2, radius * 2);
  ::SetWindowRgn(hwnd, rgn, FALSE);

  const PopoverLayout layout = ComputePopoverLayout(
      static_cast<int>(rows_.size()), width_, row_height_, vpad_);

  ::SetBkMode(dc, TRANSPARENT);
  HFONT font = ::CreateFontW(
      -std::max(11, row_height_ / 2), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  HGDIOBJ old_font = font != nullptr ? ::SelectObject(dc, font) : nullptr;

  const int hpad = std::max(4, (width_ * kHPadLogical) /
                                   std::max(1, kMaxWidthLogical));
  const int check_col =
      std::max(12, (row_height_ * kCheckColLogical) / kRowHeightLogical);

  for (int i = 0; i < static_cast<int>(layout.rows.size()); ++i) {
    const PopoverRowRect& r = layout.rows[i];
    if (i == hovered_) {
      RECT hr{r.left, r.top, r.right, r.bottom};
      HBRUSH hb = ::CreateSolidBrush(kHoverBg);
      ::FillRect(dc, &hr, hb);
      ::DeleteObject(hb);
    }
    const bool selected = rows_[i].selected;
    ::SetTextColor(dc, selected ? kSelectedText : kText);
    // Leading tick column for the current selection.
    if (selected) {
      RECT tick{r.left + hpad, r.top, r.left + check_col, r.bottom};
      ::DrawTextW(dc, L"✓", 1, &tick,
                  DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX);
    }
    RECT tr{r.left + check_col, r.top, r.right - hpad, r.bottom};
    ::DrawTextW(dc, rows_[i].label.c_str(),
                static_cast<int>(rows_[i].label.size()), &tr,
                DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX |
                    DT_END_ELLIPSIS);
  }

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

void PreRecordingBarPopover::Hide() {
  if (!visible_) {
    return;
  }
  visible_ = false;
  if (::GetCapture() == hwnd_) {
    ::ReleaseCapture();
  }
  if (hwnd_ != nullptr) {
    ::ShowWindow(hwnd_, SW_HIDE);
  }
  hovered_ = -1;
  on_pick_ = nullptr;
  rows_.clear();
}

void PreRecordingBarPopover::Destroy() {
  if (hwnd_ != nullptr) {
    if (::GetCapture() == hwnd_) {
      ::ReleaseCapture();
    }
    ::DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  visible_ = false;
  on_pick_ = nullptr;
  rows_.clear();
}

}  // namespace clingfy::capture
