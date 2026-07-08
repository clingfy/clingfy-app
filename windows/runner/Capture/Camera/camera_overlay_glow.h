#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GLOW_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GLOW_H_

// Renderer redesign P4b — the recording glow ring's pure math (macOS parity:
// macos/Runner/Overlays/Camera/CameraOverlay.swift setRecordingHighlight).
//
// The glow is LIVE-ONLY: it is drawn by the presenter on top of the shared
// CameraBubblePainter's output and must never enter the painter itself (the
// painter is the export/preview effects core — a glow there would be baked
// into exported videos, which macOS never does). These helpers are pure so
// the parity tables and the pulse waveform are unit-testable without a
// device; the D2D bake lives in camera_overlay_glow_renderer.{h,cpp}.
namespace clingfy::capture {

// Static glow styling for a strength s (wire range 0.10..1.00, clamped).
// macOS: strokeColor systemRed @ 0.60+0.40s, lineWidth 3+7s, shadowRadius
// 6+20s, shadowOpacity 0.28+0.62s. The ring path is the bubble silhouette
// inset by lineWidth/2 so the stroke stays inside the content square.
struct CameraGlowStyle {
  double line_width = 0.0;
  double stroke_alpha = 0.0;
  double halo_radius = 0.0;
  double halo_alpha = 0.0;
};
CameraGlowStyle ResolveCameraGlowStyle(double strength);

// The pulse: macOS runs an autoreversing linear opacity animation from
// 0.35+0.40s to min(1, 0.70+0.30s) with duration 0.95-0.35s seconds — i.e. a
// triangle wave with that half-period, starting at the LOW value when the
// glow turns on. Returns the layer opacity for `seconds` elapsed since
// enable. Negative time clamps to the phase origin.
double CameraGlowPulseOpacity(double strength, double seconds);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GLOW_H_
