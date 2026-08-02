#include "Capture/PreRecordingBar/pre_recording_bar_popover_model.h"

#include <algorithm>

namespace clingfy::capture {

PopoverLayout ComputePopoverLayout(int count, int width, int row_height,
                                   int vpad) {
  PopoverLayout out{};
  if (count <= 0 || width <= 0 || row_height <= 0) {
    return out;
  }
  const int pad = std::max(0, vpad);
  out.width = width;
  out.height = 2 * pad + count * row_height;
  out.rows.reserve(count);
  for (int i = 0; i < count; ++i) {
    const int top = pad + i * row_height;
    out.rows.push_back(PopoverRowRect{0, top, width, top + row_height});
  }
  return out;
}

int HitTestPopoverRow(const PopoverLayout& layout, int x, int y) {
  for (int i = 0; i < static_cast<int>(layout.rows.size()); ++i) {
    if (layout.rows[i].Contains(x, y)) {
      return i;
    }
  }
  return -1;
}

}  // namespace clingfy::capture
