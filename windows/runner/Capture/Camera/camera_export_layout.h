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
//   min_side_px — the floor, in THIS canvas's pixels. Defaults to the export
//     reference value. A surface that is smaller than the export canvas must
//     pass the floor scaled by its own short-side ratio, otherwise the floor —
//     the one non-proportional term in this function — makes its bubble
//     proportionally larger than the exported one. That is the whole reason the
//     parameter exists; see `PreviewCameraEffectScale` in
//     preview/preview_camera_renderer.h for the only caller that overrides it.
// The returned rect is always fully inside the canvas (clamped).
CameraBubbleRect ComputeCameraBubbleRect(
    double canvas_w, double canvas_h, bool has_center, double center_x,
    double center_y, const std::string& layout_preset, double size_factor,
    double min_side_px = kCameraBubbleMinSidePx);

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
//
// The table is authored in EXPORT-canvas pixels. `scale` resolves it onto a
// surface of a different size: blur radius and both offsets are lengths and
// scale; opacity is dimensionless and must NOT. The default 1.0 keeps the
// export and the live overlay byte-identical — only the preview, whose texture
// is capped at 1280x720, passes anything else. A non-positive scale degrades to
// a disabled-geometry shadow rather than producing a negative blur.
CameraShadowStyle ResolveCameraShadowStyle(int preset, double scale = 1.0);

// Index of the camera frame to HOLD at camera-file time `camera_ms`: the latest
// frame whose timestamp is <= `camera_ms`, or -1 when `camera_ms` is negative or
// before the first frame. `frame_ms_list` must be ascending. This is the pure
// statement of the held-frame pull the renderer implements incrementally; both
// stay aligned across pause/resume because the timestamps are pause-aware.
int SelectHeldCameraFrameIndex(std::int64_t camera_ms,
                               const std::vector<std::int64_t>& frame_ms_list);

// --- Phase 9.7 camera intro/outro animations --------------------------------
//
// Parity with macOS `CameraAnimationTimelineBuilder`.
//
// The zoom-emphasis "pulse" preset is still NOT ported. Read the reason
// carefully, because the older wording here invited the wrong fix: the camera
// sitting OUTSIDE the smart-zoom transform is correct and deliberate — macOS
// keeps its camera outside the zoom transform too, and a bubble that magnified
// and panned with the screen would be wrong. Do not "fix" that. The screen zoom
// reaches the camera as a scalar instead (ResolveCameraZoomScale above), which
// is how scale-with-zoom ships.
//
// What the pulse actually lacks is a zoom-LOCAL clock: it needs the time since
// the active zoom SEGMENT began. The export is close to having one
// (ZoomExportController already resolves the active segment and its start_ms);
// the preview has no segment concept at all, so porting the pulse means
// converging the preview's zoom activation with the export's. Tracked in
// TODOS.md under "Windows — preview/export parity".

// Intro presets. fade/pop/slide all ramp opacity 0→1 over introDurationMs; only
// `pop` additionally scales 0.90→1.0 (easeOutCubic) and only `slide` translates
// in from the nearest offscreen edge.
enum class CameraIntroKind { kNone, kFade, kPop, kSlide };
// Outro presets. fade/shrink/slide all ramp opacity 1→0 over the trailing
// outroDurationMs; only `shrink` scales 1.0→0.90 (easeInCubic) and only `slide`
// translates out toward the nearest offscreen edge.
enum class CameraOutroKind { kNone, kFade, kShrink, kSlide };

// Zoom emphasis presets. `pulse` throbs the bubble for as long as a zoom
// SEGMENT is active — not a one-shot bump on the zoom edge, which is what the
// name suggests and what a reader assumes. See ResolveCameraPulseScale.
enum class CameraZoomEmphasisKind { kNone, kPulse };

// Map the Dart enum names ("none"/"fade"/"pop"/"slide", "shrink", "pulse").
// Unknown or empty → kNone, so a malformed preset soft-fails to a static bubble
// (never an export error).
CameraIntroKind ParseCameraIntroKind(const std::string& name);
CameraOutroKind ParseCameraOutroKind(const std::string& name);
CameraZoomEmphasisKind ParseCameraZoomEmphasisKind(const std::string& name);

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

// --- Camera scale-with-screen-zoom -------------------------------------------
//
// Parity with macOS `CameraTransformTimelineBuilder.resolvedScale`. When the
// user picks the `scaleWithScreenZoom` behaviour the bubble grows with the
// smart zoom, taking `multiplier` of the zoom's excess: at screen zoom 2.0 and
// the default multiplier 0.35 the bubble renders 1.35x.
//
// This does NOT put the camera inside the screen-zoom transform, and must not:
// a bubble that magnifies AND pans with the screen would be wrong, and macOS
// keeps its camera outside the zoom transform too (the bubble is a sibling of
// the zoomed layer, never a child). The zoom reaches the camera only as this
// scalar; everything else about the bubble stays in canvas space.
//
//   zoom_behavior — the CameraZoomBehavior enum name. Anything other than
//     "scaleWithScreenZoom" (including empty / unknown) means a fixed bubble.
//   multiplier — 0..1 fraction of the zoom excess the bubble adopts; clamped.
//   screen_zoom — the SMOOTHED per-frame zoom, floored at 1.0 so a zoom-out
//     never shrinks the bubble.
//   layout_preset — "backgroundBehind" opts out entirely (macOS parity: a
//     full-canvas camera has no meaningful "grow with the zoom").
// Returns a multiplier >= 1.0. Pure + unit-tested.
//
// FIDELITY NOTE: Windows applies the result as a render transform, so the
// border stroke and the pre-baked shadow bitmap scale WITH it, where macOS
// re-renders both at the new frame size. At the default 0.35 multiplier
// (1.175x at a 2x zoom) this is not visible; at multiplier 1.0 with a 3x zoom
// the border reads thicker and the upscaled shadow softer than macOS would
// draw them.
double ResolveCameraZoomScale(const std::string& zoom_behavior,
                              double multiplier, double screen_zoom,
                              const std::string& layout_preset);

struct CameraAnimationParams {
  CameraIntroKind intro = CameraIntroKind::kNone;
  CameraOutroKind outro = CameraOutroKind::kNone;
  int intro_duration_ms = 0;
  int outro_duration_ms = 0;
  // Composed scale from ResolveCameraZoomScale for THIS frame (1.0 = fixed).
  // Lives here rather than as a separate argument because it multiplies into
  // the same scale the intro/outro presets produce, exactly as macOS composes
  // `additionalScale = introScale * outroScale * pulseScale` on top of the
  // zoom-scaled frame.
  double zoom_scale = 1.0;

  // --- Zoom emphasis (the pulse). ---
  // Loop-invariant: preset + strength come from the composition and never
  // change per frame.
  CameraZoomEmphasisKind emphasis = CameraZoomEmphasisKind::kNone;
  double emphasis_strength = 0.0;
  // Per-frame zoom-SEGMENT state, and the reason this feature waited for the
  // shared segment builder. `zoom_in_segment` is NOT "the smoothed zoom is
  // above 1" — that stays true through the whole ease-out tail after a segment
  // ends, which would keep the throb running with no owning segment and then
  // cut it dead mid-cycle. It is membership in a half-open [start_ms, end_ms)
  // segment, which both legs now resolve through ZoomSegmentStateAt.
  //
  // `zoom_local_seconds` is measured from the SEGMENT's start, not from the
  // click and not from the frame clock. At 2 Hz a 200 ms disagreement is ~144
  // degrees of phase, so a per-click or per-leg clock would show the bubble
  // growing in the editor exactly where the export shows it shrinking.
  bool zoom_in_segment = false;
  double zoom_local_seconds = 0.0;
};

// The pulse's throb frequency. macOS parity (`pulseFrequencyHz`).
inline constexpr double kCameraPulseFrequencyHz = 2.0;

// The pulse's scale multiplier for one frame. Pure + unit-tested.
//
// Returns exactly 1.0 unless the preset is `pulse` AND a segment is active, so
// the bubble rests at its authored size between zooms. Inside a segment it runs
// `1 + strength*0.5*(1 - cos(2π·2Hz·t))` — a continuous throb of amplitude
// `strength`, NOT a one-shot bump. It starts at exactly 1.0 (cos 0 = 1) and
// returns to 1.0 at the end of every cycle, so the snap back when a segment
// ends is only as large as wherever the cycle happened to be.
//
// `strength` is clamped to [0, 0.20] and a non-finite value reads as 0 (i.e.
// no throb) rather than propagating NaN into the render transform. macOS
// clamps to the same band at its parser.
double ResolveCameraPulseScale(CameraZoomEmphasisKind preset, double strength,
                               bool in_segment, double local_seconds);

// Whether anything at all perturbs the resting bubble this frame — an
// intro/outro preset, a live zoom scale, or the pulse. Lets the renderer skip
// the animated draw path entirely and stay byte-identical to the static bubble.
//
// The emphasis term is deliberately preset-only, NOT `&& zoom_in_segment`: it
// must stay loop-invariant so it cannot flip mid-clip and change which draw
// path a frame takes. macOS gates the same way (`hasPresentationEffects`).
inline bool CameraHasPresentationEffects(const CameraAnimationParams& p) {
  return p.intro != CameraIntroKind::kNone ||
         p.outro != CameraOutroKind::kNone || p.zoom_scale != 1.0 ||
         p.emphasis != CameraZoomEmphasisKind::kNone;
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
//
// ORDER MATTERS, and it is the macOS order: the zoom scale and the intro/outro
// scale compose into one uniform scale about the bubble centre, the SCALED rect
// is then nudged back inside the canvas, and only then is the slide translation
// added. Clamping after the slide instead would drag a slide-out bubble back
// on-screen and silently break the outro. Keeping the clamp here (rather than
// in the painter) is also why the painter can stay a dumb transform.
CameraAnimationOutput ResolveCameraAnimation(const CameraAnimationParams& params,
                                             std::int64_t frame_ms,
                                             std::int64_t total_duration_ms,
                                             const CameraBubbleRect& bubble,
                                             double canvas_w, double canvas_h,
                                             CameraSlideEdge edge);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_LAYOUT_H_
