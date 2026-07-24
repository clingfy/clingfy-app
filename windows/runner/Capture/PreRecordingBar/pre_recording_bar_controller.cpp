#include "Capture/PreRecordingBar/pre_recording_bar_controller.h"

#include <windowsx.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <string>
#include <vector>

#include "Bridge/Devices/audio_source_enumerator.h"
#include "Bridge/Devices/device_record.h"
#include "Bridge/Devices/video_source_enumerator.h"
#include "Bridge/native_selection_changed_publisher.h"
#include "Bridge/pre_recording_bar_action_publisher.h"
#include "Capture/PreRecordingBar/pre_recording_bar_model.h"
#include "Capture/PreRecordingBar/pre_recording_bar_popover.h"

namespace clingfy::capture {

namespace {

constexpr wchar_t kWindowClassName[] = L"ClingfyPreRecordingBar";
constexpr UINT kMsgSync = WM_APP + 1;  // re-place + repaint from latest state.
constexpr UINT kMsgHide = WM_APP + 2;

// WorkflowPhase wire value for idle (mirrors the Dart enum) — the ->idle edge
// resets the per-cycle dismissed flag.
constexpr int kPhaseIdle = 0;

// Work area of the monitor the bar currently sits on, falling back to the
// primary display's full bounds.
RECT MonitorWorkArea(HWND hwnd) {
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
  return work;
}

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &PreRecordingBarController::WndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

// Palette (parity spirit with the recording indicator pill + macOS accent).
constexpr COLORREF kBarBg = RGB(28, 28, 30);
constexpr COLORREF kNormalTint = RGB(200, 200, 205);
constexpr COLORREF kSelectedTint = RGB(64, 156, 255);   // control-accent blue.
constexpr COLORREF kDisabledTint = RGB(110, 110, 115);
constexpr COLORREF kRecordRed = RGB(255, 69, 58);
constexpr COLORREF kUpdatePurple = RGB(137, 87, 229);

COLORREF TintFor(BarButtonStyle style) {
  switch (style) {
    case BarButtonStyle::kSelected:
      return kSelectedTint;
    case BarButtonStyle::kDisabled:
      return kDisabledTint;
    case BarButtonStyle::kNormal:
      return kNormalTint;
  }
  return kNormalTint;
}

// The short label under/beside each button. ASCII placeholders for Slice 4;
// Slice 6 swaps these for the localized `preRecordingBar.*` strings pushed from
// Dart. Empty for icon-only buttons (close / record).
const wchar_t* LabelFor(BarButtonId id) {
  switch (id) {
    case BarButtonId::kDisplay:
      return L"Display";
    case BarButtonId::kWindow:
      return L"Window";
    case BarButtonId::kArea:
      return L"Area";
    case BarButtonId::kCamera:
      return L"Camera";
    case BarButtonId::kMic:
      return L"Mic";
    case BarButtonId::kSystemAudio:
      return L"System";
    case BarButtonId::kUpdate:
      return L"Update";
    default:
      return L"";
  }
}

}  // namespace

std::atomic<bool> PreRecordingBarController::suppress_window_for_testing_{false};

PreRecordingBarController& PreRecordingBarController::Instance() {
  static PreRecordingBarController instance;
  return instance;
}

PreRecordingBarController::~PreRecordingBarController() { Shutdown(); }

void PreRecordingBarController::set_suppress_window_for_testing(bool suppress) {
  suppress_window_for_testing_.store(suppress);
}

PreRecordingBarInputs PreRecordingBarController::inputs_for_testing() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return inputs_;
}

LRESULT CALLBACK PreRecordingBarController::WndProc(HWND hwnd, UINT msg,
                                                    WPARAM wparam,
                                                    LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<PreRecordingBarController*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case kMsgSync:
      if (self != nullptr) {
        self->PlaceWindow(hwnd);
      }
      ::ShowWindow(hwnd, SW_SHOWNA);  // show without stealing focus.
      ::InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    case kMsgHide:
      // Dismiss any open picker first — a phase change (e.g. recording starts)
      // can hide the bar while the dropdown is up.
      if (self != nullptr) {
        self->popover_.Hide();
      }
      ::ShowWindow(hwnd, SW_HIDE);
      return 0;
    case WM_LBUTTONDOWN:
      if (self != nullptr) {
        self->HandleClick(hwnd, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      }
      return 0;
    case WM_SETCURSOR:
      // Hand cursor over an enabled button, arrow elsewhere. LOWORD(lparam) is
      // the hit-test area; only restyle the client area.
      if (self != nullptr && LOWORD(lparam) == HTCLIENT) {
        POINT pt{};
        ::GetCursorPos(&pt);
        ::ScreenToClient(hwnd, &pt);
        if (self->PointOnEnabledButton(hwnd, pt.x, pt.y)) {
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

void PreRecordingBarController::Paint(HWND hwnd) {
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

  PreRecordingBarInputs inputs;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    inputs = inputs_;
  }
  const std::array<BarButtonSpec, kBarButtonCount> specs =
      ComputeBarButtons(inputs);
  const BarLayout layout = ComputeBarLayout(cw, ch, specs);
  const RecordGlyph record_glyph = RecordGlyphFor(inputs.phase);

  // Double buffer so the whole bar lands in one blit (no partial-frame tear).
  HDC mem = ::CreateCompatibleDC(hdc);
  HBITMAP buffer = ::CreateCompatibleBitmap(hdc, cw, ch);
  HGDIOBJ old_bmp = (mem != nullptr && buffer != nullptr)
                        ? ::SelectObject(mem, buffer)
                        : nullptr;
  HDC dc = (mem != nullptr && buffer != nullptr) ? mem : hdc;

  // Dark rounded background.
  RECT full{0, 0, cw, ch};
  HBRUSH bg = ::CreateSolidBrush(kBarBg);
  ::FillRect(dc, &full, bg);
  ::DeleteObject(bg);
  const int radius = std::min(ch / 2, 28);
  HRGN rgn = ::CreateRoundRectRgn(0, 0, cw + 1, ch + 1, radius * 2, radius * 2);
  ::SetWindowRgn(hwnd, rgn, FALSE);  // window owns the region now.

  ::SetBkMode(dc, TRANSPARENT);
  HFONT font = ::CreateFontW(
      -std::max(9, ch / 5), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  HGDIOBJ old_font = font != nullptr ? ::SelectObject(dc, font) : nullptr;
  HGDIOBJ old_pen = ::SelectObject(dc, ::GetStockObject(NULL_PEN));

  for (int i = 0; i < kBarButtonCount; ++i) {
    const BarButtonRect& r = layout.buttons[i];
    if (r.id == BarButtonId::kNone) {
      continue;
    }
    const BarButtonStyle style = specs[i].style;
    const int bw = r.right - r.left;
    const int bh = r.bottom - r.top;
    const int cx = r.left + bw / 2;
    const int cy = r.top + bh / 2;

    if (r.id == BarButtonId::kRecord) {
      // Record disc: red stop square while live, red ring while idle, dimmed
      // dot while busy (a real spinner is Slice 5+ polish).
      const int d = std::min(bw, bh) - std::max(2, bh / 6);
      const int left = cx - d / 2;
      const int top = cy - d / 2;
      HBRUSH disc = ::CreateSolidBrush(
          record_glyph == RecordGlyph::kBusy ? kDisabledTint : kRecordRed);
      HGDIOBJ prev = ::SelectObject(dc, disc);
      if (record_glyph == RecordGlyph::kStop) {
        RECT sq{left, top, left + d, top + d};
        ::FillRect(dc, &sq, disc);
      } else {
        ::Ellipse(dc, left, top, left + d, top + d);
      }
      ::SelectObject(dc, prev);
      ::DeleteObject(disc);
      continue;
    }

    if (r.id == BarButtonId::kClose) {
      // Close: an "x" drawn as two strokes.
      HPEN pen = ::CreatePen(PS_SOLID, std::max(1, bh / 12), TintFor(style));
      HGDIOBJ prev = ::SelectObject(dc, pen);
      const int inset = std::max(2, bw / 3);
      ::MoveToEx(dc, r.left + inset, r.top + inset, nullptr);
      ::LineTo(dc, r.right - inset, r.bottom - inset);
      ::MoveToEx(dc, r.right - inset, r.top + inset, nullptr);
      ::LineTo(dc, r.left + inset, r.bottom - inset);
      ::SelectObject(dc, prev);
      ::DeleteObject(pen);
      continue;
    }

    // Labeled buttons (display/window/area/camera/mic/system/pauseResume/
    // update): a rounded chip tinted by style, with a short label. Update keeps
    // its purple accent; a selected chip fills faintly with the accent.
    const bool selected = style == BarButtonStyle::kSelected;
    COLORREF tint = TintFor(style);
    if (r.id == BarButtonId::kUpdate) {
      tint = kUpdatePurple;
    }
    if (selected) {
      RECT chip{r.left, r.top, r.right, r.bottom};
      HBRUSH fill = ::CreateSolidBrush(RGB(40, 62, 92));  // faint accent wash.
      const int cr = std::min(bh / 2, 12);
      HRGN chip_rgn = ::CreateRoundRectRgn(chip.left, chip.top, chip.right + 1,
                                           chip.bottom + 1, cr * 2, cr * 2);
      ::FillRgn(dc, chip_rgn, fill);
      ::DeleteObject(chip_rgn);
      ::DeleteObject(fill);
    }

    const wchar_t* label = LabelFor(r.id);
    std::wstring text = label;
    if (r.id == BarButtonId::kPauseResume) {
      text = inputs.phase == 3 /*paused*/ ? L"Resume" : L"Pause";
    }
    ::SetTextColor(dc, tint);
    RECT tr{r.left, r.top, r.right, r.bottom};
    ::DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &tr,
                DT_SINGLELINE | DT_CENTER | DT_VCENTER | DT_NOPREFIX |
                    DT_END_ELLIPSIS);
  }

  ::SelectObject(dc, old_pen);
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

void PreRecordingBarController::PlaceWindow(HWND hwnd) {
  const RECT work = MonitorWorkArea(hwnd);
  const UINT dpi = ::GetDpiForWindow(hwnd);
  const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  const int height =
      std::max(1, static_cast<int>(std::lround(kBarBaseHeight * scale)));

  PreRecordingBarInputs inputs;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    inputs = inputs_;
  }
  const std::array<BarButtonSpec, kBarButtonCount> specs =
      ComputeBarButtons(inputs);
  const int width = std::max(1, BarContentWidth(specs, height));

  // Centered horizontally, tucked up from the bottom of the work area (macOS
  // default position). Clamp so it never spills off a narrow work area. RECT
  // fields are LONG; work in int so std::clamp deduces one type.
  const int wl = static_cast<int>(work.left);
  const int wt = static_cast<int>(work.top);
  const int wr = static_cast<int>(work.right);
  const int wb = static_cast<int>(work.bottom);
  const int bottom_inset = static_cast<int>(std::lround(28.0 * scale));
  int x = wl + ((wr - wl) - width) / 2;
  int y = wb - height - bottom_inset;
  x = std::clamp(x, wl, std::max(wl, wr - width));
  y = std::clamp(y, wt, std::max(wt, wb - height));

  ::SetWindowPos(hwnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
}

namespace {

// NativeSelectionType strings (mirror Dart native_bar_action.dart). Slice 6a
// covers mic + camera; display/window arrive in 6b.
constexpr const char* kSelTypeMic = "mic";
constexpr const char* kSelTypeCamera = "camera";

// Widen a UTF-8 device name (the enumerators produce UTF-8 std::string) to the
// UTF-16 the GDI text APIs want. Empty in -> empty out.
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return {};
  }
  const int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                        static_cast<int>(utf8.size()), nullptr,
                                        0);
  if (len <= 0) {
    return {};
  }
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                        static_cast<int>(utf8.size()), out.data(), len);
  return out;
}

// Resolve the button under a client point together with its style + rect, from
// the current pushed inputs. Returns kNone on a miss.
struct HitButton {
  BarButtonId id = BarButtonId::kNone;
  BarButtonStyle style = BarButtonStyle::kNormal;
  BarButtonRect rect;
};

HitButton ResolveHit(HWND hwnd, const PreRecordingBarInputs& inputs, int x,
                     int y) {
  RECT client{};
  ::GetClientRect(hwnd, &client);
  const std::array<BarButtonSpec, kBarButtonCount> specs =
      ComputeBarButtons(inputs);
  const BarLayout layout = ComputeBarLayout(client.right - client.left,
                                            client.bottom - client.top, specs);
  const BarButtonId id = HitTestBarButton(layout, x, y);
  if (id == BarButtonId::kNone) {
    return {};
  }
  for (int i = 0; i < kBarButtonCount; ++i) {
    if (specs[i].id == id) {
      return {id, specs[i].style, layout.buttons[i]};
    }
  }
  return {};
}

}  // namespace

void PreRecordingBarController::HandleClick(HWND hwnd, int x, int y) {
  PreRecordingBarInputs inputs;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    inputs = inputs_;
  }
  const HitButton hit = ResolveHit(hwnd, inputs, x, y);
  if (hit.id == BarButtonId::kNone ||
      hit.style == BarButtonStyle::kDisabled) {
    return;  // background, or a phase-disabled control — no reverse call.
  }

  // Mic / camera open a native device dropdown (Slice 6a) instead of forwarding
  // a tap. Anchor it to the button's screen rect.
  if (hit.id == BarButtonId::kMic || hit.id == BarButtonId::kCamera) {
    RECT anchor{hit.rect.left, hit.rect.top, hit.rect.right, hit.rect.bottom};
    ::MapWindowPoints(hwnd, nullptr, reinterpret_cast<POINT*>(&anchor),
                      2);  // client -> screen (both corners).
    if (hit.id == BarButtonId::kMic) {
      OpenMicPicker(anchor);
    } else {
      OpenCameraPicker(anchor);
    }
    return;
  }

  clingfy::bridge::PreRecordingBarActionPublisher::Instance().EmitAction(
      BarActionFor(hit.id, inputs.phase));
}

void PreRecordingBarController::OpenMicPicker(const RECT& anchor_screen) {
  std::string selected;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    selected = inputs_.selected_audio_source_id;
  }
  const bool none_selected = selected.empty() || selected == "__none__";
  const std::vector<clingfy::bridge::devices::AudioSourceRecord> devices =
      clingfy::bridge::devices::EnumerateAudioInputs();

  std::vector<PreRecordingBarPopover::Row> rows;
  std::vector<std::string> ids;  // row (index+1) -> device id (row 0 = none).
  rows.push_back({L"Do not record audio", none_selected});
  for (const auto& d : devices) {
    rows.push_back(
        {Utf8ToWide(d.name), !none_selected && d.id == selected});
    ids.push_back(d.id);
  }

  popover_.Show(rows, anchor_screen, [ids](int row) {
    auto& pub = clingfy::bridge::NativeSelectionChangedPublisher::Instance();
    if (row == 0) {
      pub.EmitNoneSelection(kSelTypeMic);  // "Do not record audio".
    } else if (row - 1 < static_cast<int>(ids.size())) {
      pub.EmitStringSelection(kSelTypeMic, ids[row - 1]);
    }
  });
}

void PreRecordingBarController::OpenCameraPicker(const RECT& anchor_screen) {
  std::string selected;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    selected = inputs_.selected_cam_id;
  }
  const bool none_selected =
      selected.empty() || selected == "none" || selected == "__none__";
  // One attempt only on an informational refresh — a longer retry budget would
  // stall the overlay thread on camera-less machines.
  const std::vector<clingfy::bridge::devices::VideoSourceRecord> devices =
      clingfy::bridge::devices::EnumerateVideoInputs(/*max_attempts=*/1);

  std::vector<PreRecordingBarPopover::Row> rows;
  std::vector<std::string> ids;
  rows.push_back({L"No camera", none_selected});
  for (const auto& d : devices) {
    rows.push_back(
        {Utf8ToWide(d.name), !none_selected && d.id == selected});
    ids.push_back(d.id);
  }

  popover_.Show(rows, anchor_screen, [ids](int row) {
    auto& pub = clingfy::bridge::NativeSelectionChangedPublisher::Instance();
    if (row == 0) {
      pub.EmitNoneSelection(kSelTypeCamera);  // "No camera".
    } else if (row - 1 < static_cast<int>(ids.size())) {
      pub.EmitStringSelection(kSelTypeCamera, ids[row - 1]);
    }
  });
}

bool PreRecordingBarController::PointOnEnabledButton(HWND hwnd, int x, int y) {
  PreRecordingBarInputs inputs;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    inputs = inputs_;
  }
  const HitButton hit = ResolveHit(hwnd, inputs, x, y);
  return hit.id != BarButtonId::kNone &&
         hit.style != BarButtonStyle::kDisabled;
}

bool PreRecordingBarController::EnsureRunning() {
  if (suppress_window_for_testing_.load()) {
    return false;
  }
  if (running_.load()) {
    return true;
  }
  std::promise<bool> ready;
  std::future<bool> fut = ready.get_future();
  thread_ =
      std::thread(&PreRecordingBarController::ThreadMain, this, &ready);
  const bool ok = fut.get();
  if (!ok && thread_.joinable()) {
    thread_.join();
  }
  return ok;
}

void PreRecordingBarController::ThreadMain(std::promise<bool>* ready) {
  thread_id_ = ::GetCurrentThreadId();
  EnsureClassRegistered();

  // Opaque topmost tool window (NOT layered — same lesson as the camera overlay
  // + indicator). Created HIDDEN; a show is posted on demand.
  HWND hwnd = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName,
      L"Clingfy Recorder Bar", WS_POPUP, 0, 0, kBarBaseHeight * 6,
      kBarBaseHeight, nullptr, nullptr, ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    ready->set_value(false);
    return;
  }

  // Never let the bar be burned into the recording.
  ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);

  hwnd_.store(hwnd);
  running_.store(true);
  ready->set_value(true);  // created HIDDEN — a sync/show reveals on demand.

  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  running_.store(false);
  hwnd_.store(nullptr);
  // Destroy the picker popover on this thread (it was created here) before the
  // bar window itself.
  popover_.Destroy();
  ::DestroyWindow(hwnd);
}

void PreRecordingBarController::ApplyVisibility() {
  bool should_show = false;
  if (enabled_.load() && !dismissed_.load()) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    should_show = ShouldShowBar(inputs_);
  }

  if (should_show) {
    if (!EnsureRunning()) {
      return;  // window creation failed / suppressed — nothing to show.
    }
    visible_.store(true);
    if (HWND hwnd = hwnd_.load(); hwnd != nullptr) {
      ::PostMessageW(hwnd, kMsgSync, 0, 0);
    }
    return;
  }

  visible_.store(false);
  if (HWND hwnd = hwnd_.load(); hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgHide, 0, 0);
  }
}

void PreRecordingBarController::SetEnabled(bool enabled) {
  enabled_.store(enabled);
  ApplyVisibility();
}

void PreRecordingBarController::Show() {
  dismissed_.store(false);
  ApplyVisibility();
}

void PreRecordingBarController::Toggle() {
  if (visible_.load()) {
    dismissed_.store(true);
  } else {
    dismissed_.store(false);
  }
  ApplyVisibility();
}

void PreRecordingBarController::SetState(const PreRecordingBarInputs& inputs) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    // A non-idle -> idle transition starts a fresh cycle: a bar the user
    // dismissed last cycle should reappear (macOS `setAppPhase`).
    if (inputs.phase == kPhaseIdle && last_phase_ != kPhaseIdle) {
      dismissed_.store(false);
    }
    last_phase_ = inputs.phase;
    inputs_ = inputs;
  }
  ApplyVisibility();
  // ApplyVisibility posts kMsgSync when visible, which re-places (resizes to the
  // new button set) and repaints. When it stays visible across a state change
  // that alters styling but not visibility, still refresh.
  if (visible_.load()) {
    if (HWND hwnd = hwnd_.load(); hwnd != nullptr) {
      ::PostMessageW(hwnd, kMsgSync, 0, 0);
    }
  }
}

void PreRecordingBarController::Shutdown() {
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
}

}  // namespace clingfy::capture
