// Step 0 of Windows Phase 5: source-of-truth zoom-and-cursor constants
// extracted from the macOS engine and the Dart heuristic so the upcoming
// Windows live-render preview can reach pixel-equivalent behavior. Pure
// constants header — no behavior, no allocations, no platform headers.
//
// Source provenance (every value here mirrors a value in one of these
// files; if any of those change, this header must change too):
//
//   * lib/core/zoom/zoom_focus_heuristic.dart
//       kZoomCursorMotionThresholdPx
//
//   * lib/core/post_processing/settings/post_processing_settings_controller.dart
//       _postZoomFactor default + clamp range + write epsilon
//       _postZoomEffectEnabled default
//
//   * macos/Runner/Capture/Zoom/ZoomFollowSmoother.swift
//       minStrength / maxStrength / defaultStrength
//       minDtSeconds / maxDtSeconds / defaultReferenceFPS
//       alpha(strength, dt, fps) formula
//
//   * macos/Runner/Capture/Zoom/ZoomHysteresis.swift
//       zoomInDelay / zoomOutDelay / minZoomOnDuration
//
//   * macos/Runner/Capture/Zoom/ZoomTimelineBuilder.swift
//       default simulation FPS, gap-merge threshold,
//       minimum-segment-duration rule (2 frames at simulation FPS)
//
//   * macos/Runner/Capture/Export/CompositionBuilder.swift
//       CAKeyframeAnimation.calculationMode == .linear for the zoom
//       transform track — i.e. zoom samples interpolate linearly between
//       keyframes; the perceived smoothness comes from the per-frame
//       exponential smoothing in ZoomFollowSmoother, not a keyframe
//       easing curve. Two facts the Windows compositor must mirror.
//
// Intentionally NOT in this header (so the next reader is not misled):
//
//   * Cubic-bezier control points. The macOS zoom track does not use a
//     cubic-bezier curve. easeInCubic / easeOutCubic in
//     CameraAnimationTimelineBuilder.swift are camera-overlay intro /
//     outro / pulse animations, not screen-zoom timing. The screen zoom
//     uses linear keyframes + exponential smoothing.
//
//   * Cursor highlight (radial halo / click ripple) radius. No such
//     constant exists in the macOS source today. The Windows POC may
//     introduce one but it will not be a port — it will be a new design
//     decision documented at that point.
//
//   * Zoom "hold" duration between cursor events. No explicit hold
//     constant exists in the macOS source. The follow-cursor behavior
//     is continuous: the smoother converges toward the latest cursor
//     position frame-by-frame. The hysteresis delays below control
//     whether zoom is active at all, not how long a transform is held.
//
// All durations are seconds (double). All thresholds matching pixel
// space match the Dart-side coordinate system (CursorSample.x / .y).

#ifndef WINDOWS_RUNNER_PREVIEW_ZOOM_EASING_CONSTANTS_H_
#define WINDOWS_RUNNER_PREVIEW_ZOOM_EASING_CONSTANTS_H_

namespace clingfy::preview {

// --- Smart-zoom focus heuristic ----------------------------------------
// Source: lib/core/zoom/zoom_focus_heuristic.dart
//
// When the cursor moves less than this many pixels across a segment, the
// segment is treated as "static" and zoom focuses on a fixed target
// instead of following the cursor.
inline constexpr double kZoomCursorMotionThresholdPx = 12.0;

// --- User-configurable zoom magnitude ----------------------------------
// Source: lib/core/post_processing/settings/post_processing_settings_controller.dart
//
// The actual zoom factor at render time is a per-recording user setting
// (postZoomFactor). These define the default, the valid range, and the
// epsilon used to skip no-op writes back to SharedPreferences.
inline constexpr double kZoomFactorDefault = 1.5;
inline constexpr double kZoomFactorMin = 1.0;
inline constexpr double kZoomFactorMax = 3.0;
inline constexpr double kZoomFactorWriteEpsilon = 0.001;

// Whether the zoom effect is on by default when a project opens.
inline constexpr bool kZoomEffectEnabledDefault = true;

// --- Follow-cursor exponential smoother --------------------------------
// Source: macos/Runner/Capture/Zoom/ZoomFollowSmoother.swift
//
// The smoother runs once per rendered frame and lerps the current zoom
// center toward the latest cursor position by `alpha`, where:
//
//   normalizedFrames = clampedDt * kZoomFollowReferenceFPS
//   alpha            = 1.0 - pow(1.0 - strength, normalizedFrames)
//   currentCenter    = currentCenter + (targetCenter - currentCenter) * alpha
//
// `strength` is clamped to [kZoomFollowStrengthMin, kZoomFollowStrengthMax]
// before use. `dt` is clamped to [kZoomFollowMinDtSeconds,
// kZoomFollowMaxDtSeconds] before use. These bounds protect against
// degenerate dt values (paused tabs, very long frame stalls).
inline constexpr double kZoomFollowStrengthDefault = 0.15;
inline constexpr double kZoomFollowStrengthMin = 0.05;
inline constexpr double kZoomFollowStrengthMax = 0.50;

inline constexpr double kZoomFollowMinDtSeconds = 1.0 / 240.0;  // ~0.004166s
inline constexpr double kZoomFollowMaxDtSeconds = 1.0 / 15.0;   // ~0.066666s

inline constexpr double kZoomFollowReferenceFPS = 60.0;

// --- Zoom active / inactive hysteresis ---------------------------------
// Source: macos/Runner/Capture/Zoom/ZoomHysteresis.swift
//
// The stable zoom state only flips to active after the "raw wanted" flag
// has been continuously true for kZoomInDelaySeconds, and only flips
// back to inactive after raw has been continuously false for
// kZoomOutDelaySeconds. Additionally, once active, zoom must stay
// active for at least kZoomMinOnSeconds before it can flip off — this
// prevents single-frame flickers on rapid sprite-id switches.
inline constexpr double kZoomInDelaySeconds = 0.2;
inline constexpr double kZoomOutDelaySeconds = 0.3;
inline constexpr double kZoomMinOnSeconds = 0.30;

// --- Zoom timeline builder (auto-segment generation) -------------------
// Source: macos/Runner/Capture/Zoom/ZoomTimelineBuilder.swift
//
// The auto-zoom timeline is simulated at this FPS by stepping the
// hysteresis once per simulated frame. Generated segments closer than
// kZoomTimelineGapMergeMs are merged into one segment. After merging,
// any segment shorter than two simulated frames is dropped.
inline constexpr double kZoomTimelineSimulationFPS = 60.0;
inline constexpr int kZoomTimelineGapMergeMs = 120;
inline constexpr int kZoomTimelineMinSegmentFrames = 2;

// --- Export-side zoom keyframe interpolation ---------------------------
// Source: macos/Runner/Capture/Export/CompositionBuilder.swift
//
// The exported zoom track interpolates LINEARLY between samples. The
// Windows export-path compositor must do the same — otherwise the
// exported MP4 will diverge from the live preview, which is rendered
// frame-by-frame via the exponential smoother.
//
// Strongly-typed enum to make the choice visible at call sites; this
// header is the single place the constant is named.
enum class ZoomKeyframeInterpolation {
  kLinear,
};
inline constexpr ZoomKeyframeInterpolation kZoomKeyframeInterpolation =
    ZoomKeyframeInterpolation::kLinear;

}  // namespace clingfy::preview

#endif  // WINDOWS_RUNNER_PREVIEW_ZOOM_EASING_CONSTANTS_H_
