#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_LAYOUT_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_LAYOUT_H_

#include <cstdint>
#include <string>
#include <vector>

// Phase 9.4 — where the camera bubble lands on the export canvas.
//
// Pure geometry, no Win32 / D2D, so the placement rules are unit-tested in
// isolation. Mirrors the macOS `CameraLayoutResolver`: the bubble is a SQUARE of
// side `max(96px, min(canvasW, canvasH) * sizeFactor)`, centered on either the
// user's manual normalized center or a layout-preset default corner, then
// clamped so it never spills off the canvas.
namespace clingfy::capture {

struct CameraBubbleRect {
  double x = 0.0;
  double y = 0.0;
  double width = 0.0;
  double height = 0.0;
};

// Smallest bubble side in output pixels (matches macOS). Exposed for tests.
inline constexpr double kCameraBubbleMinSidePx = 96.0;

// Compute the bubble rect on a `canvas_w` x `canvas_h` output.
//   has_center / center_x / center_y — the manual normalized center (0..1) when
//     the user dragged the bubble; ignored when has_center is false.
//   layout_preset — the CameraLayoutPreset enum name (e.g. "overlayBottomRight");
//     used only when has_center is false. Unknown / full-canvas presets fall back
//     to the bottom-right corner for 9.4 (side-by-side / stacked are deferred).
//   size_factor — fraction of the shorter canvas side; clamped to [0.08, 0.45].
// The returned rect is always fully inside the canvas (clamped).
CameraBubbleRect ComputeCameraBubbleRect(double canvas_w, double canvas_h,
                                         bool has_center, double center_x,
                                         double center_y,
                                         const std::string& layout_preset,
                                         double size_factor);

// --- Camera/screen time alignment (the Phase 9.2 `startOffsetMs` sync key) ---

// The camera-file time (ms) that lines up with an export frame presented at
// recording-relative `frame_ms`. Negative result => the camera had not started
// yet at that point in the recording (draw nothing).
inline std::int64_t CameraTimeMsForFrame(std::int64_t frame_ms,
                                         std::int64_t start_offset_ms) {
  return frame_ms - start_offset_ms;
}

// Index of the camera frame to HOLD at camera-file time `camera_ms`: the latest
// frame whose timestamp is <= `camera_ms`, or -1 when `camera_ms` is negative or
// before the first frame. `frame_ms_list` must be ascending. This is the pure
// statement of the held-frame pull the renderer implements incrementally; both
// stay aligned across pause/resume because the timestamps are pause-aware.
int SelectHeldCameraFrameIndex(std::int64_t camera_ms,
                               const std::vector<std::int64_t>& frame_ms_list);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_LAYOUT_H_
