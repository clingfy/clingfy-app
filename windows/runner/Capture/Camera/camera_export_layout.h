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
//     the user dragged the bubble; ignored when has_center is false. `center_y`
//     is y-UP (0 = canvas BOTTOM): that is the `cameraNormalizedCenter` wire
//     contract shared with Dart (which stores `1 - dy`) and macOS (which
//     consumes it as a bottom-up CGRect), so it is flipped into Direct2D's
//     y-DOWN space here. The preset centers below are already y-DOWN and are
//     not flipped.
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

// --- Phase 9.5 camera shadow styling (parity with macOS shadowStyle) ---------

struct CameraShadowStyle {
  bool enabled = false;
  double opacity = 0.0;      // 0..1 black shadow alpha
  double blur_radius = 0.0;  // px (used as the D2D blur input radius)
  double offset_x = 0.0;     // px, canvas space (D2D y-DOWN)
  double offset_y = 0.0;     // px, canvas space (D2D y-DOWN, so + is downward)
};

// Map the Dart `cameraShadowPreset` (0 = none, 1/2/3 = soft/medium/strong) to a
// concrete shadow style. Values mirror the macOS `shadowStyle(for:)` table; the
// macOS y-offsets are in a y-UP space (negative = down), so they are sign-
// flipped here for D2D's y-DOWN canvas (shadow drops downward). Preset <=0 or
// unknown → disabled. Pure + unit-tested.
CameraShadowStyle ResolveCameraShadowStyle(int preset);

// Index of the camera frame to HOLD at camera-file time `camera_ms`: the latest
// frame whose timestamp is <= `camera_ms`, or -1 when `camera_ms` is negative or
// before the first frame. `frame_ms_list` must be ascending. This is the pure
// statement of the held-frame pull the renderer implements incrementally; both
// stay aligned across pause/resume because the timestamps are pause-aware.
int SelectHeldCameraFrameIndex(std::int64_t camera_ms,
                               const std::vector<std::int64_t>& frame_ms_list);

// --- Phase 9.7 camera intro/outro animations --------------------------------
//
// Parity with macOS `CameraAnimationTimelineBuilder`. The zoom-emphasis "pulse"
// preset is intentionally NOT ported here: it is gated on live smart-zoom events
// and the Windows camera deliberately sits OUTSIDE the smart-zoom transform, so
// there is no zoom-local time to drive it.

// Intro presets. fade/pop/slide all ramp opacity 0→1 over introDurationMs; only
// `pop` additionally scales 0.90→1.0 (easeOutCubic) and only `slide` translates
// in from the nearest offscreen edge.
enum class CameraIntroKind { kNone, kFade, kPop, kSlide };
// Outro presets. fade/shrink/slide all ramp opacity 1→0 over the trailing
// outroDurationMs; only `shrink` scales 1.0→0.90 (easeInCubic) and only `slide`
// translates out toward the nearest offscreen edge.
enum class CameraOutroKind { kNone, kFade, kShrink, kSlide };

// Map the Dart enum names ("none"/"fade"/"pop"/"slide", "shrink"). Unknown or
// empty → kNone, so a malformed preset soft-fails to a static bubble (never an
// export error).
CameraIntroKind ParseCameraIntroKind(const std::string& name);
CameraOutroKind ParseCameraOutroKind(const std::string& name);

// The screen edge a `slide` preset enters from / exits toward, by VISUAL meaning
// (kTop = top of the screen). Resolved in D2D y-DOWN space.
enum class CameraSlideEdge { kLeft, kRight, kTop, kBottom };

// Resolve the slide edge the macOS way: a manually-positioned bubble uses the
// nearest canvas edge to its center; a preset-positioned bubble uses the
// preset's side. Pure + unit-tested.
CameraSlideEdge ResolveCameraSlideEdge(const std::string& layout_preset,
                                       bool has_center,
                                       const CameraBubbleRect& bubble,
                                       double canvas_w, double canvas_h);

struct CameraAnimationParams {
  CameraIntroKind intro = CameraIntroKind::kNone;
  CameraOutroKind outro = CameraOutroKind::kNone;
  int intro_duration_ms = 0;
  int outro_duration_ms = 0;
};

// Whether any intro/outro effect is active (lets the renderer skip the animated
// draw path entirely and stay byte-identical to the static bubble).
inline bool CameraHasPresentationEffects(const CameraAnimationParams& p) {
  return p.intro != CameraIntroKind::kNone || p.outro != CameraOutroKind::kNone;
}

// Per-frame presentation result. `opacity` multiplies the styled-bubble alpha;
// `scale` is an extra uniform scale about the bubble center; `translate_x/y` are
// canvas-pixel offsets (D2D y-DOWN). Identity (1,1,0,0) when nothing applies.
struct CameraAnimationOutput {
  double opacity = 1.0;
  double scale = 1.0;
  double translate_x = 0.0;
  double translate_y = 0.0;
};

// Resolve the intro/outro presentation for an export frame presented at
// recording-relative `frame_ms` of a `total_duration_ms` clip. `bubble` is the
// resting (static) bubble rect; `edge` is the resolved slide edge. Mirrors macOS
// `CameraAnimationTimelineBuilder.resolve` (opacity ramps, pop/shrink scale,
// slide translation). Pure + unit-tested.
CameraAnimationOutput ResolveCameraAnimation(const CameraAnimationParams& params,
                                             std::int64_t frame_ms,
                                             std::int64_t total_duration_ms,
                                             const CameraBubbleRect& bubble,
                                             double canvas_w, double canvas_h,
                                             CameraSlideEdge edge);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_LAYOUT_H_
