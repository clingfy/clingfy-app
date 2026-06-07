#ifndef RUNNER_CAPTURE_ZOOM_ZOOM_FOLLOW_SMOOTHER_H_
#define RUNNER_CAPTURE_ZOOM_ZOOM_FOLLOW_SMOOTHER_H_

// Phase 8.3 — 1:1 port of macOS `ZoomFollowSmoother.swift` (the alpha/lerp math).
//
// Per-frame exponential smoothing: alpha = 1 - (1-strength)^(dt*refFPS), with
// strength and dt clamped to the bounds in zoom_easing_constants.h. Used to ease
// both the zoom level and the zoom center toward their targets each frame so the
// exported zoom matches the documented "smoothness comes from the smoother, not a
// keyframe curve" behavior. Pure (free functions) → unit-tested for parity.
namespace clingfy::capture {

double ClampFollowStrength(double value);
double ClampFollowDtSeconds(double value);

// alpha in [0,1]. `reference_fps <= 0 / non-finite` falls back to the default.
double ZoomFollowAlpha(double base_strength, double dt_seconds,
                       double reference_fps);

// current + (target - current) * clamp(alpha, 0, 1).
double ZoomFollowLerp(double current, double target, double alpha);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_ZOOM_ZOOM_FOLLOW_SMOOTHER_H_
