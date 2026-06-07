#include "Capture/Zoom/zoom_follow_smoother.h"

#include <cmath>

#include "preview/zoom_easing_constants.h"

namespace clingfy::capture {

namespace {
bool IsFinite(double v) { return std::isfinite(v); }
}  // namespace

double ClampFollowStrength(double value) {
  const double source = IsFinite(value)
                            ? value
                            : clingfy::preview::kZoomFollowStrengthDefault;
  if (source < clingfy::preview::kZoomFollowStrengthMin) {
    return clingfy::preview::kZoomFollowStrengthMin;
  }
  if (source > clingfy::preview::kZoomFollowStrengthMax) {
    return clingfy::preview::kZoomFollowStrengthMax;
  }
  return source;
}

double ClampFollowDtSeconds(double value) {
  const double source =
      IsFinite(value) ? value : (1.0 / clingfy::preview::kZoomFollowReferenceFPS);
  if (source < clingfy::preview::kZoomFollowMinDtSeconds) {
    return clingfy::preview::kZoomFollowMinDtSeconds;
  }
  if (source > clingfy::preview::kZoomFollowMaxDtSeconds) {
    return clingfy::preview::kZoomFollowMaxDtSeconds;
  }
  return source;
}

double ZoomFollowAlpha(double base_strength, double dt_seconds,
                       double reference_fps) {
  const double strength = ClampFollowStrength(base_strength);
  const double clamped_dt = ClampFollowDtSeconds(dt_seconds);
  const double safe_fps = (IsFinite(reference_fps) && reference_fps > 0.0)
                              ? reference_fps
                              : clingfy::preview::kZoomFollowReferenceFPS;
  const double normalized_frames = clamped_dt * safe_fps;
  const double alpha = 1.0 - std::pow(1.0 - strength, normalized_frames);
  if (alpha < 0.0) return 0.0;
  if (alpha > 1.0) return 1.0;
  return alpha;
}

double ZoomFollowLerp(double current, double target, double alpha) {
  double a = IsFinite(alpha) ? alpha : 0.0;
  if (a < 0.0) a = 0.0;
  if (a > 1.0) a = 1.0;
  return current + (target - current) * a;
}

}  // namespace clingfy::capture
