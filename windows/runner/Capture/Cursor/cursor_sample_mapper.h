#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_SAMPLE_MAPPER_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_SAMPLE_MAPPER_H_

#include <cstdint>

// Phase 8.1 — pure cursor coordinate mapping + sample-dedup decision.
//
// The #1 correctness risk of the cursor sidecar is mapping a screen-space cursor
// position into the captured frame's local pixel space, which differs per target
// mode. This header keeps that math pure (no Win32) so it is unit-tested without
// a real monitor / window / GPU, exactly like Phase 7.2's `ResolveCropBox`. The
// sampler resolves the per-mode origin via Win32 and feeds it in here.
namespace clingfy::capture {

// Result of mapping a screen-space cursor point into capture-local space.
struct CursorLocalPoint {
  std::int32_t x = 0;    // capture-local px (may be negative / out of bounds)
  std::int32_t y = 0;
  bool visible = false;  // true iff (x,y) lies inside [0,width) x [0,height)
};

// Map a screen (virtual-desktop physical px) cursor point into capture-local px.
// `origin_x/origin_y` is the captured region's top-left in screen px:
//   * display: the monitor's `rcMonitor.{left,top}`
//   * area:    `rcMonitor.{left,top}` + the crop box `{x,y}`
//   * window:  the window CONTENT top-left — `DWMWA_EXTENDED_FRAME_BOUNDS`, NOT
//              `GetWindowRect` (which includes the invisible drop-shadow border,
//              so the WGC content frame's (0,0) sits inside it).
// `width/height` are the captured frame dimensions (even px). The app is
// PerMonitorV2, so all inputs are physical pixels and no DPI scaling is applied
// here.
CursorLocalPoint MapScreenToCaptureLocal(std::int32_t screen_x,
                                         std::int32_t screen_y,
                                         std::int32_t origin_x,
                                         std::int32_t origin_y,
                                         std::int32_t width,
                                         std::int32_t height);

// Dedup decision for the sample stream: emit a sample only when the cursor moved
// or changed visibility, with a heartbeat so a long static period still anchors
// the timeline (downstream zoom/render interpolate between anchors). Pure +
// testable. `heartbeat_ms <= 0` disables the heartbeat.
bool ShouldEmitCursorSample(bool have_prev, std::int32_t prev_x,
                            std::int32_t prev_y, bool prev_visible,
                            std::int32_t cur_x, std::int32_t cur_y,
                            bool cur_visible, std::int64_t ms_since_last_emit,
                            std::int64_t heartbeat_ms);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_SAMPLE_MAPPER_H_
