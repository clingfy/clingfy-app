#include "Overlay/display_identify_overlay.h"

#include <shellscalingapi.h>

#include <algorithm>
#include <mutex>

namespace clingfy::overlay {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyDisplayIdentifyOverlay";
constexpr UINT_PTR kDismissTimerId = 1;

// Card metrics at 100% scale; multiplied by the monitor's DPI factor.
constexpr int kCardWidth = 420;
constexpr int kCardHeight = 280;
constexpr int kOrdinalPointSize = 96;
constexpr int kSubtitlePointSize = 13;

struct CardWindow {
  int ordinal = 0;
  std::wstring label;
  UINT dpi = 96;
  HFONT ordinal_font = nullptr;
  HFONT subtitle_font = nullptr;
  // Set by WM_NCCREATE. CreateWindowExW can return null AFTER WM_NCCREATE ran
  // (a WM_CREATE-stage failure, a CBT hook, or this class's own
  // WM_DISPLAYCHANGE handler firing on the half-created window), in which case
  // WM_NCDESTROY has already freed this object — so the caller's failure path
  // must not free it a second time.
  bool adopted = false;
};

void DestroyCard(CardWindow* card) {
  if (card == nullptr) {
    return;
  }
  if (card->ordinal_font != nullptr) {
    ::DeleteObject(card->ordinal_font);
  }
  if (card->subtitle_font != nullptr) {
    ::DeleteObject(card->subtitle_font);
  }
  delete card;
}

std::vector<HWND>& LiveWindows() {
  static std::vector<HWND> windows;
  return windows;
}

UINT DpiForMonitor(HMONITOR monitor) {
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  if (FAILED(::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y)) ||
      dpi_x == 0) {
    return 96;
  }
  return dpi_x;
}

// Point size -> logical units at this monitor's DPI. Without this a 96 pt
// glyph renders half-size on a 200% display.
HFONT MakeFont(int point_size, UINT dpi, int weight) {
  return ::CreateFontW(-::MulDiv(point_size, static_cast<int>(dpi), 72), 0, 0,
                       0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                       OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                       CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                       L"Segoe UI");
}

void PaintCard(HWND hwnd, CardWindow* card) {
  PAINTSTRUCT ps{};
  const HDC hdc = ::BeginPaint(hwnd, &ps);

  RECT client{};
  ::GetClientRect(hwnd, &client);

  // Double-buffered: the window is a fixed size, so one back buffer per paint
  // is cheap and avoids a visible tear on the rounded edge.
  const HDC mem_dc = ::CreateCompatibleDC(hdc);
  const HBITMAP mem_bmp = ::CreateCompatibleBitmap(
      hdc, client.right - client.left, client.bottom - client.top);
  const HGDIOBJ old_bmp = ::SelectObject(mem_dc, mem_bmp);

  // CreateCompatibleBitmap hands back a DDB whose contents are undefined, and
  // RoundRect paints only inside the rounded path — so without this the four
  // corner wedges reach the screen as whatever was in the GDI pool. Every
  // other overlay in this repo clears first.
  ::PatBlt(mem_dc, 0, 0, client.right - client.left,
           client.bottom - client.top, BLACKNESS);

  const HBRUSH fill = ::CreateSolidBrush(RGB(18, 18, 22));
  const HPEN border = ::CreatePen(PS_SOLID, 2, RGB(72, 72, 84));
  const HGDIOBJ old_brush = ::SelectObject(mem_dc, fill);
  const HGDIOBJ old_pen = ::SelectObject(mem_dc, border);
  const int radius = ::MulDiv(28, static_cast<int>(card->dpi), 96);
  ::RoundRect(mem_dc, client.left, client.top, client.right, client.bottom,
              radius, radius);

  ::SetBkMode(mem_dc, TRANSPARENT);

  const int subtitle_band =
      ::MulDiv(48, static_cast<int>(card->dpi), 96);

  RECT ordinal_rect = client;
  ordinal_rect.bottom -= subtitle_band;
  const HGDIOBJ old_font = ::SelectObject(mem_dc, card->ordinal_font);
  ::SetTextColor(mem_dc, RGB(255, 255, 255));
  const std::wstring ordinal_text = std::to_wstring(card->ordinal);
  ::DrawTextW(mem_dc, ordinal_text.c_str(),
              static_cast<int>(ordinal_text.size()), &ordinal_rect,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);

  if (!card->label.empty()) {
    RECT subtitle_rect = client;
    subtitle_rect.top = client.bottom - subtitle_band;
    subtitle_rect.left += ::MulDiv(18, static_cast<int>(card->dpi), 96);
    subtitle_rect.right -= ::MulDiv(18, static_cast<int>(card->dpi), 96);
    ::SelectObject(mem_dc, card->subtitle_font);
    ::SetTextColor(mem_dc, RGB(210, 210, 220));
    ::DrawTextW(mem_dc, card->label.c_str(),
                static_cast<int>(card->label.size()), &subtitle_rect,
                DT_CENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  }

  ::BitBlt(hdc, 0, 0, client.right - client.left, client.bottom - client.top,
           mem_dc, 0, 0, SRCCOPY);

  ::SelectObject(mem_dc, old_font);
  ::SelectObject(mem_dc, old_pen);
  ::SelectObject(mem_dc, old_brush);
  ::DeleteObject(border);
  ::DeleteObject(fill);
  ::SelectObject(mem_dc, old_bmp);
  ::DeleteObject(mem_bmp);
  ::DeleteDC(mem_dc);

  ::EndPaint(hwnd, &ps);
}

LRESULT CALLBACK IdentifyWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                 LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    auto* created = static_cast<CardWindow*>(cs->lpCreateParams);
    if (created != nullptr) {
      // Ownership transfers here, exactly once.
      created->adopted = true;
    }
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(created));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  auto* card =
      reinterpret_cast<CardWindow*>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA));

  switch (msg) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT:
      if (card != nullptr) {
        PaintCard(hwnd, card);
        return 0;
      }
      break;
    case WM_TIMER:
      if (wparam == kDismissTimerId) {
        ::KillTimer(hwnd, kDismissTimerId);
        ::DestroyWindow(hwnd);
        return 0;
      }
      break;
    case WM_DISPLAYCHANGE:
      // A stale digit is worse than no digit: the moment the display
      // configuration changes, the number on this glass may be wrong.
      ::DestroyWindow(hwnd);
      return 0;
    case WM_NCDESTROY: {
      if (card != nullptr) {
        ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        DestroyCard(card);
      }
      auto& live = LiveWindows();
      live.erase(std::remove(live.begin(), live.end(), hwnd), live.end());
      break;
    }
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &IdentifyWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

}  // namespace

void ShowDisplayIdentify(const std::vector<IdentifyTarget>& targets,
                         int duration_ms) {
  EnsureClassRegistered();
  // A second flash always replaces the first — the Win32 analogue of the
  // macOS side's dismiss token.
  HideDisplayIdentify();

  const int clamped = (std::max)(400, (std::min)(6000, duration_ms));

  for (const auto& target : targets) {
    const UINT dpi = DpiForMonitor(target.monitor);
    const int card_w = ::MulDiv(kCardWidth, static_cast<int>(dpi), 96);
    const int card_h = ::MulDiv(kCardHeight, static_cast<int>(dpi), 96);
    const int x =
        target.rect.left + (target.rect.right - target.rect.left - card_w) / 2;
    const int y =
        target.rect.top + (target.rect.bottom - target.rect.top - card_h) / 2;

    auto* card = new CardWindow();
    card->ordinal = target.ordinal;
    card->label = target.label;
    card->dpi = dpi;
    card->ordinal_font = MakeFont(kOrdinalPointSize, dpi, FW_BOLD);
    card->subtitle_font = MakeFont(kSubtitlePointSize, dpi, FW_NORMAL);

    // Opaque, NOT WS_EX_LAYERED and no window region: layered + region +
    // WDA_EXCLUDEFROMCAPTURE renders nothing on some hybrid GPUs, a scar
    // already documented in recording_indicator_controller.cpp and
    // camera_floating_overlay.cpp. A centred card rather than a full-monitor
    // cover is what makes an opaque window acceptable here.
    const HWND hwnd = ::CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
        kWindowClassName, L"", WS_POPUP, x, y, card_w, card_h, nullptr, nullptr,
        ::GetModuleHandleW(nullptr), card);
    if (hwnd == nullptr) {
      // Only free when WM_NCCREATE never adopted it — otherwise WM_NCDESTROY
      // already did, and freeing again is a heap double-free plus two
      // DeleteObject calls on dead handles.
      if (!card->adopted) {
        DestroyCard(card);
      }
      continue;
    }

    ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    ::SetTimer(hwnd, kDismissTimerId, static_cast<UINT>(clamped), nullptr);
    LiveWindows().push_back(hwnd);
  }
}

void HideDisplayIdentify() {
  // Copy first: WM_NCDESTROY mutates the live list while we walk it.
  const std::vector<HWND> live = LiveWindows();
  for (const HWND hwnd : live) {
    ::DestroyWindow(hwnd);
  }
  LiveWindows().clear();
}

}  // namespace clingfy::overlay
