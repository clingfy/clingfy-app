// Unit tests for the recording glow ring's pure math (renderer redesign P4b)
// — the macOS parity tables (CameraOverlay.swift setRecordingHighlight) and
// the pulse waveform. No D2D device; the bake is covered by the headless
// pixel tests and the on-screen probe.

#include "Capture/Camera/camera_overlay_glow.h"

#include <gtest/gtest.h>

#include <algorithm>

namespace clingfy::capture {
namespace {

TEST(ResolveCameraGlowStyle, MatchesTheMacosTables) {
  // lineWidth 3+7s, stroke alpha 0.60+0.40s, shadowRadius 6+20s,
  // shadowOpacity 0.28+0.62s.
  const CameraGlowStyle full = ResolveCameraGlowStyle(1.0);
  EXPECT_DOUBLE_EQ(full.line_width, 10.0);
  EXPECT_DOUBLE_EQ(full.stroke_alpha, 1.0);
  EXPECT_DOUBLE_EQ(full.halo_radius, 26.0);
  EXPECT_DOUBLE_EQ(full.halo_alpha, 0.90);

  const CameraGlowStyle faint = ResolveCameraGlowStyle(0.10);
  EXPECT_DOUBLE_EQ(faint.line_width, 3.7);
  EXPECT_DOUBLE_EQ(faint.stroke_alpha, 0.64);
  EXPECT_DOUBLE_EQ(faint.halo_radius, 8.0);
  EXPECT_DOUBLE_EQ(faint.halo_alpha, 0.342);
}

TEST(ResolveCameraGlowStyle, ClampsToTheWireRange) {
  const CameraGlowStyle below = ResolveCameraGlowStyle(0.0);
  EXPECT_DOUBLE_EQ(below.line_width, 3.7);  // clamped to 0.10
  const CameraGlowStyle above = ResolveCameraGlowStyle(7.0);
  EXPECT_DOUBLE_EQ(above.line_width, 10.0);  // clamped to 1.00
}

TEST(CameraGlowPulseOpacity, TriangleWaveMatchesTheMacosAnimation) {
  // s=1.0: lo = 0.75, hi = min(1, 1.0) = 1.0, half-period 0.60 s.
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(1.0, 0.0), 0.75);   // fromValue
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(1.0, 0.30), 0.875);  // mid-ramp
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(1.0, 0.60), 1.0);   // toValue
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(1.0, 1.20), 0.75);  // autoreversed
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(1.0, 2.40), 0.75);  // periodic

  // s=0.5: lo = 0.55, hi = 0.85, half-period 0.775 s.
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(0.5, 0.0), 0.55);
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(0.5, 0.775), 0.85);
}

TEST(CameraGlowPulseOpacity, NegativeTimeClampsToThePhaseOrigin) {
  EXPECT_DOUBLE_EQ(CameraGlowPulseOpacity(1.0, -5.0), 0.75);
}

TEST(CameraGlowPulseOpacity, StaysWithinTheConfiguredBand) {
  for (double s : {0.10, 0.35, 0.70, 1.00}) {
    const double lo = 0.35 + 0.40 * s;
    const double hi = std::min(1.0, 0.70 + 0.30 * s);
    for (double t = 0.0; t < 5.0; t += 0.05) {
      const double v = CameraGlowPulseOpacity(s, t);
      EXPECT_GE(v, lo - 1e-9) << "s=" << s << " t=" << t;
      EXPECT_LE(v, hi + 1e-9) << "s=" << s << " t=" << t;
    }
  }
}

}  // namespace
}  // namespace clingfy::capture
