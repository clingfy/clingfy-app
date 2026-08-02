#include "Capture/Indicator/recording_indicator_controller.h"

#include <windowsx.h>

#include <algorithm>
#include <string>
#include <utility>

#include "Bridge/app_window_anchor.h"
#include "Bridge/indicator_event_publisher.h"
#include "Capture/Indicator/recording_indicator_model.h"

namespace clingfy::capture {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyRecordingIndicator";
constexpr UINT_PTR kTickTimerId = 1;
constexpr UINT kTickIntervalMs = 250;  // 4 Hz — keeps the seconds tick crisp.
constexpr UINT kMsgShow = WM_APP + 1;
constexpr UINT kMsgHide = WM_APP + 2;
constexpr UINT kMsgRepaint = WM_APP + 3;
constexpr UINT kMsgReplace = WM_APP + 4;  // re-run PlaceWindow (pin toggled).

// Logical (96-dpi) pill size. Wide enough for the red dot + "00:00:00" + the
// pause and stop controls on the right.
constexpr int kBaseWidth = 220;
constexpr int kBaseHeight = 44;

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
    case kMsgRepaint:
      ::InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    case kMsgReplace:
      if (self != nullptr) {
        self->PlaceWindow(hwnd);
      }
      ::InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    case WM_NCHITTEST: {
      // Coexist drag with the Slice 2 controls: HTCLIENT over a button (so the
      // click reaches WM_LBUTTONDOWN), HTCAPTION over the rest while unpinned
      // (so the pill drags), HTCLIENT everywhere while pinned (non-movable).
      if (self == nullptr) {
        return ::DefWindowProcW(hwnd, msg, wparam, lparam);
      }
      POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};  // screen coords
      ::ScreenToClient(hwnd, &pt);
      RECT client{};
      ::GetClientRect(hwnd, &client);
      const IndicatorHitZone zone = HitTestIndicatorZone(
          client.right - client.left, client.bottom - client.top,
          self->state_.load(), self->can_pause_resume_.load(), pt.x, pt.y);
      if (zone == IndicatorHitZone::kControl) {
        return HTCLIENT;
      }
      return self->pinned_.load() ? HTCLIENT : HTCAPTION;
    }
    case WM_EXITSIZEMOVE:
      // End of a user drag (the HTCAPTION modal move loop). Programmatic
      // SetWindowPos moves do NOT raise this, so PlaceWindow can't self-trigger
      // a write-back.
      if (self != nullptr) {
        self->OnDragEnded(hwnd);
      }
      return 0;
    case WM_TIMER:
      if (wparam == kTickTimerId && self != nullptr &&
          self->visible_.load() && ::IsWindowVisible(hwnd)) {
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    case WM_LBUTTONDOWN:
      if (self != nullptr) {
        self->HandleClick(hwnd, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      }
      return 0;
    case WM_SETCURSOR:
      // Hand cursor over the controls, arrow elsewhere. LOWORD(lparam) is the
      // hit-test area; only style the client area.
      if (self != nullptr && LOWORD(lparam) == HTCLIENT) {
        POINT pt{};
        ::GetCursorPos(&pt);
        ::ScreenToClient(hwnd, &pt);
        RECT client{};
        ::GetClientRect(hwnd, &client);
        const IndicatorButtonLayout layout = ComputeIndicatorButtons(
            client.right - client.left, client.bottom - client.top,
            self->state_.load(), self->can_pause_resume_.load());
        if (HitTestIndicatorButton(layout, pt.x, pt.y) !=
            IndicatorButton::kNone) {
          ::SetCursor(::LoadCursorW(nullptr, IDC_HAND));
          return TRUE;
        }
      }
      return ::DefWindowProcW(hwnd, msg, wparam, lparam);
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

  const IndicatorVisualState state = state_.load();
  const bool paused = state == IndicatorVisualState::kPaused;

  // Session dot on the left: red while recording, amber while paused.
  const int dot = std::max(8, ch / 3);
  const int dot_x = std::max(6, ch / 4);
  const int dot_y = (ch - dot) / 2;
  HBRUSH dot_brush =
      ::CreateSolidBrush(paused ? RGB(255, 179, 64) : RGB(255, 69, 58));
  HGDIOBJ old_brush = ::SelectObject(dc, dot_brush);
  HGDIOBJ old_pen = ::SelectObject(dc, ::GetStockObject(NULL_PEN));
  ::Ellipse(dc, dot_x, dot_y, dot_x + dot, dot_y + dot);
  ::SelectObject(dc, old_pen);
  ::SelectObject(dc, old_brush);
  ::DeleteObject(dot_brush);

  // Control buttons on the right (pause/resume + stop). Compute first so the
  // timer text can be clipped to the space left of them.
  const IndicatorButtonLayout buttons = ComputeIndicatorButtons(
      cw, ch, state, can_pause_resume_.load());
  const int controls_left =
      buttons.primary.present ? buttons.primary.left
                              : (buttons.stop.present ? buttons.stop.left : cw);

  // Timer text, clipped so it never runs under the controls.
  ::SetBkMode(dc, TRANSPARENT);
  ::SetTextColor(dc, RGB(245, 245, 247));
  HFONT font = ::CreateFontW(
      -std::max(12, ch / 2), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  HGDIOBJ old_font = font != nullptr ? ::SelectObject(dc, font) : nullptr;
  RECT text_rect{dot_x + dot + 8, 0, std::max(dot_x + dot + 8, controls_left - 8),
                 ch};
  ::DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &text_rect,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX |
                  DT_END_ELLIPSIS);
  if (old_font != nullptr) {
    ::SelectObject(dc, old_font);
  }
  if (font != nullptr) {
    ::DeleteObject(font);
  }

  // Glyphs: pause = two vertical bars, resume = right-pointing triangle, stop =
  // filled square. Owner-drawn (no child controls) so a WS_EX_NOACTIVATE popup
  // stays click-through-free and never steals focus from the recorded app.
  HBRUSH glyph = ::CreateSolidBrush(RGB(235, 235, 237));
  HGDIOBJ prev_brush = ::SelectObject(dc, glyph);
  HGDIOBJ prev_pen = ::SelectObject(dc, ::GetStockObject(NULL_PEN));
  if (buttons.primary.present) {
    const IndicatorButtonRect& b = buttons.primary;
    const int bw = b.right - b.left;
    const int bh = b.bottom - b.top;
    if (paused) {
      // Resume: right-pointing triangle inscribed in the button.
      const int inset = std::max(2, bw / 4);
      POINT tri[3] = {
          {b.left + inset, b.top + inset},
          {b.left + inset, b.bottom - inset},
          {b.right - inset, b.top + bh / 2},
      };
      ::Polygon(dc, tri, 3);
    } else {
      // Pause: two vertical bars.
      const int bar_w = std::max(2, bw / 5);
      const int inset_y = std::max(2, bh / 5);
      const int gap = std::max(2, bar_w);
      const int total = bar_w * 2 + gap;
      const int start_x = b.left + (bw - total) / 2;
      RECT bar1{start_x, b.top + inset_y, start_x + bar_w, b.bottom - inset_y};
      RECT bar2{start_x + bar_w + gap, b.top + inset_y,
                start_x + bar_w + gap + bar_w, b.bottom - inset_y};
      ::FillRect(dc, &bar1, glyph);
      ::FillRect(dc, &bar2, glyph);
    }
  }
  if (buttons.stop.present) {
    const IndicatorButtonRect& b = buttons.stop;
    const int bw = b.right - b.left;
    const int bh = b.bottom - b.top;
    const int inset_x = std::max(2, bw / 4);
    const int inset_y = std::max(2, bh / 4);
    RECT sq{b.left + inset_x, b.top + inset_y, b.right - inset_x,
            b.bottom - inset_y};
    HBRUSH stop_brush = ::CreateSolidBrush(RGB(255, 69, 58));
    ::FillRect(dc, &sq, stop_brush);
    ::DeleteObject(stop_brush);
  }
  ::SelectObject(dc, prev_pen);
  ::SelectObject(dc, prev_brush);
  ::DeleteObject(glyph);

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
  const bool restoring_drag = !pinned_.load() && last_origin_.has_value();
  // Default (never dragged) placement follows the display showing the main app
  // window, matching macOS `NSScreen.main` -- resolving from the pill's own
  // window pins it to the primary display. A remembered drag origin instead
  // clamps against the display it was dropped on, so dragging the pill to a
  // second monitor sticks.
  const RECT work = restoring_drag
                        ? clingfy::WorkAreaForPoint(*last_origin_)
                        : clingfy::AnchorWorkArea(hwnd);
  const UINT dpi = ::GetDpiForWindow(hwnd);
  const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  // Size always comes from the DPI-scaled base; the pinned top-right position
  // is the default and the fallback when the pill was never dragged.
  const IndicatorRect snap = ComputeIndicatorRect(
      work.left, work.top, work.right, work.bottom, scale, kBaseWidth,
      kBaseHeight);

  int x = snap.x;
  int y = snap.y;
  if (restoring_drag) {
    // Restore the remembered drag origin, re-clamped: the monitor/DPI may have
    // changed since the drop, so the old origin could now be off-screen.
    const IndicatorRect clamped = ClampIndicatorToWorkArea(
        last_origin_->x, last_origin_->y, snap.width, snap.height, work.left,
        work.top, work.right, work.bottom);
    x = clamped.x;
    y = clamped.y;
  }
  ::SetWindowPos(hwnd, HWND_TOPMOST, x, y, snap.width, snap.height,
                 SWP_NOACTIVATE);
}

void RecordingIndicatorController::OnDragEnded(HWND hwnd) {
  if (pinned_.load()) {
    return;  // pinned windows don't move; nothing to remember.
  }
  RECT wr{};
  if (::GetWindowRect(hwnd, &wr) == 0) {
    return;
  }
  // Clamp against the display the pill was dropped on, not the anchor display,
  // so a drag onto a second monitor is remembered there.
  const RECT work = clingfy::WorkAreaForWindow(hwnd);
  const IndicatorRect clamped = ClampIndicatorToWorkArea(
      wr.left, wr.top, wr.right - wr.left, wr.bottom - wr.top, work.left,
      work.top, work.right, work.bottom);
  last_origin_ = POINT{clamped.x, clamped.y};
  // If the drop left the pill partly off-screen, pull it back in. SWP_NOSIZE
  // keeps the current size; this programmatic move raises no WM_EXITSIZEMOVE.
  if (clamped.x != wr.left || clamped.y != wr.top) {
    ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.x, clamped.y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE);
  }
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
  state_.store(IndicatorVisualState::kRecording);
  visible_.store(true);
  if (HWND hwnd = hwnd_.load(); hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgShow, 0, 0);
  }
}

void RecordingIndicatorController::SetState(IndicatorVisualState state) {
  state_.store(state);
  if (HWND hwnd = hwnd_.load(); hwnd != nullptr && visible_.load()) {
    ::PostMessageW(hwnd, kMsgRepaint, 0, 0);
  }
}

void RecordingIndicatorController::SetPinned(bool pinned) {
  pinned_.store(pinned);
  // Apply live: snap to the corner when pinning, restore the dragged origin
  // when unpinning. PlaceWindow reads pinned_ + last_origin_.
  if (HWND hwnd = hwnd_.load(); hwnd != nullptr && visible_.load()) {
    ::PostMessageW(hwnd, kMsgReplace, 0, 0);
  }
}

void RecordingIndicatorController::HandleClick(HWND hwnd, int x, int y) {
  RECT client{};
  ::GetClientRect(hwnd, &client);
  const IndicatorVisualState state = state_.load();
  const IndicatorButtonLayout layout = ComputeIndicatorButtons(
      client.right - client.left, client.bottom - client.top, state,
      can_pause_resume_.load());
  switch (HitTestIndicatorButton(layout, x, y)) {
    case IndicatorButton::kPrimary:
      // The primary control means resume while paused, pause while recording.
      if (state == IndicatorVisualState::kPaused) {
        clingfy::bridge::IndicatorEventPublisher::Instance().EmitResumeTapped();
      } else {
        clingfy::bridge::IndicatorEventPublisher::Instance().EmitPauseTapped();
      }
      break;
    case IndicatorButton::kStop:
      clingfy::bridge::IndicatorEventPublisher::Instance().EmitStopTapped();
      break;
    case IndicatorButton::kNone:
      break;
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
