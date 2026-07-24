#ifndef RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_POPOVER_H_
#define RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_POPOVER_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

// Slice 6 (Windows pre-recording bar pickers): the native dropdown popover that
// lists device rows above a tapped picker button. Lives on the bar's overlay
// thread — created lazily and driven by that thread's existing message loop, so
// there is no second thread and no nested modal loop (the popover is just a
// second window on the same thread). Selection fires an on-pick callback with
// the row index; clicking anywhere outside dismisses (via mouse capture). GDI
// double-buffered; topmost `WS_EX_NOACTIVATE` tool window excluded from capture.
//
// Threading: every method here runs on the bar overlay thread (called from the
// controller's click handler, which is already on that thread), so the row +
// callback state needs no lock.
namespace clingfy::capture {

class PreRecordingBarPopover {
 public:
  struct Row {
    std::wstring label;
    bool selected = false;
  };

  PreRecordingBarPopover() = default;
  ~PreRecordingBarPopover();

  PreRecordingBarPopover(const PreRecordingBarPopover&) = delete;
  PreRecordingBarPopover& operator=(const PreRecordingBarPopover&) = delete;

  // Show the popover listing `rows`, anchored to `anchor` (screen coords of the
  // tapped button) — placed above it, or below when there's no room. `on_pick`
  // fires with the clicked row index. Replaces any currently-shown popover.
  void Show(const std::vector<Row>& rows, const RECT& anchor,
            std::function<void(int)> on_pick);

  // Hide + release mouse capture. Idempotent.
  void Hide();

  // Destroy the window (app teardown). Idempotent.
  void Destroy();

  bool visible() const { return visible_; }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  bool EnsureWindow();
  void Paint(HWND hwnd);
  void Position(HWND hwnd, const RECT& anchor);
  void OnMouseMove(HWND hwnd, int client_x, int client_y);
  // A click while capturing: inside a row picks it, anywhere else dismisses.
  void OnClick(HWND hwnd, int screen_x, int screen_y);

  HWND hwnd_ = nullptr;
  bool visible_ = false;
  int row_height_ = 0;  // device px, from DPI at Show time.
  int vpad_ = 0;
  int width_ = 0;  // device px content width (fits the widest label).
  int hovered_ = -1;
  std::vector<Row> rows_;
  std::function<void(int)> on_pick_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_POPOVER_H_
