#include "Capture/Camera/camera_overlay_glow.h"

#include <algorithm>
#include <cmath>

namespace clingfy::capture {

namespace {

double ClampStrength(double strength) {
  return std::clamp(strength, 0.10, 1.00);
}

}  // namespace

CameraGlowStyle ResolveCameraGlowStyle(double strength) {
  const double s = ClampStrength(strength);
  CameraGlowStyle g;
  g.line_width = 3.0 + 7.0 * s;
  g.stroke_alpha = 0.60 + 0.40 * s;
  g.halo_radius = 6.0 + 20.0 * s;
  g.halo_alpha = 0.28 + 0.62 * s;
  return g;
}

double CameraGlowPulseOpacity(double strength, double seconds) {
  const double s = ClampStrength(strength);
  const double lo = 0.35 + 0.40 * s;
  const double hi = std::min(1.0, 0.70 + 0.30 * s);
  const double half_period = 0.95 - 0.35 * s;  // > 0 across the wire range
  const double t = std::max(0.0, seconds);
  // Triangle wave, phase 0 at the LOW end (macOS fromValue), linear ramps.
  const double phase = std::fmod(t / half_period, 2.0);
  const double up = phase <= 1.0 ? phase : 2.0 - phase;
  return lo + (hi - lo) * up;
}

}  // namespace clingfy::capture
