#include "Overlay/cursor_highlight_model.h"

#include <algorithm>
#include <cmath>

namespace clingfy::overlay {

namespace {

// macOS systemYellow (light appearance), sRGB.
constexpr double kYellowR = 255.0;
constexpr double kYellowG = 204.0;
constexpr double kYellowB = 0.0;
constexpr double kDiscAlpha = 0.25;

// The ease-out bezier (0,0)-(0.58,1)-(1,1): x and y of parameter u.
double BezierX(double u) {
  return 3.0 * (1.0 - u) * u * u * 0.58 + u * u * u;
}
double BezierY(double u) { return 3.0 * (1.0 - u) * u * u + u * u * u; }

// y for a given x. x(u) is monotonic on [0,1], so bisection is exact enough
// and cannot diverge.
double EaseOut(double x) {
  double lo = 0.0;
  double hi = 1.0;
  for (int i = 0; i < 40; ++i) {
    const double mid = 0.5 * (lo + hi);
    if (BezierX(mid) < x) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return BezierY(0.5 * (lo + hi));
}

double Coverage(double signed_distance_inside) {
  return std::clamp(signed_distance_inside + 0.5, 0.0, 1.0);
}

std::uint32_t Pack(double a, double r, double g, double b) {
  const auto c = [](double v) {
    return static_cast<std::uint32_t>(std::clamp(std::lround(v), 0L, 255L));
  };
  return (c(a * 255.0) << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
}

}  // namespace

bool CursorHighlightShouldShow(bool enabled, bool linked,
                               bool actively_recording,
                               bool session_disabled) {
  // effectiveCursorEnabledForRecording. The caller clears session_disabled
  // when the session ends, as macOS's clearSessionSuppressions does.
  const bool effective = enabled && !session_disabled;
  return linked ? (actively_recording && effective) : effective;
}

CursorHighlightPulse CursorHighlightPulseAt(double seconds_since_click) {
  CursorHighlightPulse pulse;
  if (!(seconds_since_click >= 0.0) ||
      seconds_since_click >= kCursorHighlightPulseSeconds) {
    return pulse;  // before any click, or the pulse has finished
  }
  const double eased =
      EaseOut(seconds_since_click / kCursorHighlightPulseSeconds);
  pulse.active = true;
  pulse.scale = 1.0 + (kCursorHighlightPulseMaxScale - 1.0) * eased;
  pulse.opacity = 1.0 - eased;
  return pulse;
}

int CursorHighlightWindowPx(unsigned dpi) {
  const double scale = (dpi == 0 ? 96.0 : static_cast<double>(dpi)) / 96.0;
  return static_cast<int>(std::lround(kCursorHighlightWindowDip * scale));
}

void RasterizeCursorHighlight(std::vector<std::uint32_t>* bgra, int size_px,
                              double scale, const CursorHighlightPulse& pulse) {
  const std::size_t n = static_cast<std::size_t>(std::max(size_px, 0));
  bgra->assign(n * n, 0u);
  if (size_px <= 0 || !(scale > 0.0)) {
    return;
  }
  const double centre = size_px / 2.0;
  const double disc_r = kCursorHighlightRingDip / 2.0 * scale;
  // CAShapeLayer strokes are centred on the path, and the pulse scales the
  // whole layer — path and stroke width alike — about the window's centre.
  const double ring_r =
      (kCursorHighlightRingDip / 2.0 + kCursorHighlightClickInsetDip) * scale *
      pulse.scale;
  const double ring_half_w =
      kCursorHighlightClickStrokeDip / 2.0 * scale * pulse.scale;
  const double ring_alpha = pulse.active ? pulse.opacity : 0.0;

  for (int y = 0; y < size_px; ++y) {
    for (int x = 0; x < size_px; ++x) {
      const double dx = x + 0.5 - centre;
      const double dy = y + 0.5 - centre;
      const double d = std::sqrt(dx * dx + dy * dy);

      const double disc_a = kDiscAlpha * Coverage(disc_r - d);
      double ring_a = 0.0;
      if (ring_alpha > 0.0) {
        ring_a = ring_alpha * Coverage(ring_half_w - std::abs(d - ring_r));
      }
      // The outline sits above the disc (it is the later sublayer):
      // premultiplied source-over.
      const double a = ring_a + disc_a * (1.0 - ring_a);
      if (a <= 0.0) {
        continue;
      }
      (*bgra)[static_cast<std::size_t>(y) * n + x] =
          Pack(a, kYellowR * a, kYellowG * a, kYellowB * a);
    }
  }
}

}  // namespace clingfy::overlay
