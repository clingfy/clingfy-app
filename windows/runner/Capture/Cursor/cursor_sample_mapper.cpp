#include "Capture/Cursor/cursor_sample_mapper.h"

namespace clingfy::capture {

CursorLocalPoint MapScreenToCaptureLocal(std::int32_t screen_x,
                                         std::int32_t screen_y,
                                         std::int32_t origin_x,
                                         std::int32_t origin_y,
                                         std::int32_t width,
                                         std::int32_t height) {
  CursorLocalPoint point;
  point.x = screen_x - origin_x;
  point.y = screen_y - origin_y;
  point.visible = width > 0 && height > 0 && point.x >= 0 && point.y >= 0 &&
                  point.x < width && point.y < height;
  return point;
}

bool ShouldEmitCursorSample(bool have_prev, std::int32_t prev_x,
                            std::int32_t prev_y, bool prev_visible,
                            std::int32_t cur_x, std::int32_t cur_y,
                            bool cur_visible, std::int64_t ms_since_last_emit,
                            std::int64_t heartbeat_ms) {
  if (!have_prev) {
    return true;  // always anchor the first sample.
  }
  if (cur_visible != prev_visible) {
    return true;
  }
  // A position change only matters while the cursor is visible — two
  // off-surface positions are indistinguishable downstream.
  if (cur_visible && (cur_x != prev_x || cur_y != prev_y)) {
    return true;
  }
  if (heartbeat_ms > 0 && ms_since_last_emit >= heartbeat_ms) {
    return true;
  }
  return false;
}

}  // namespace clingfy::capture
