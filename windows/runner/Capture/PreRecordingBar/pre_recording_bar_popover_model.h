#ifndef RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_POPOVER_MODEL_H_
#define RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_POPOVER_MODEL_H_

#include <vector>

// Slice 6 (Windows pre-recording bar pickers): the pure, window-free geometry
// for the native dropdown popover that lists devices when the user taps a
// picker button (mic / camera in 6a; display / window in 6b). Kept separate
// from the popover window so the row layout + hit-test are unit-testable
// headless — same split as the bar itself.
namespace clingfy::capture {

// A single row's rectangle in popover client coordinates.
struct PopoverRowRect {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;

  bool Contains(int x, int y) const {
    return x >= left && x < right && y >= top && y < bottom;
  }
};

// The laid-out popover: its client size plus one rect per row (top-to-bottom).
struct PopoverLayout {
  int width = 0;
  int height = 0;
  std::vector<PopoverRowRect> rows;
};

// Stack `count` full-width rows of `row_height`, inset top+bottom by `vpad`.
// Widths/heights are device pixels (the controller scales by DPI). A zero /
// negative count yields an empty, zero-height popover.
PopoverLayout ComputePopoverLayout(int count, int width, int row_height,
                                   int vpad);

// The index of the row under a client-coordinate point, or -1 on a miss (the
// padding bands or outside the popover).
int HitTestPopoverRow(const PopoverLayout& layout, int x, int y);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_POPOVER_MODEL_H_
