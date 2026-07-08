#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GLOW_RENDERER_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GLOW_RENDERER_H_

#include <d2d1_1.h>
#include <wrl/client.h>

#include <string>

// Renderer redesign P4b — the D2D bake for the recording glow ring.
//
// PRESENTER-SIDE ONLY: the glow must never enter the shared
// CameraBubblePainter (it would be baked into exports; macOS never exports
// it). The bake renders the ring stroke + its blurred red halo ONCE per
// style/geometry change at full configured alphas; the presenter then draws
// the bitmap per tick with the pulse opacity (CameraGlowPulseOpacity) — one
// DrawBitmap per frame, macOS CALayer-pulse parity.
namespace clingfy::capture {

// Bake the glow for a content square at (padding_px, padding_px) inside a
// (content_side + 2*padding_px)^2 window. The ring path is the bubble
// silhouette (CreateCameraShapeGeometry) inset by lineWidth/2; the halo is a
// Gaussian blur of the stroke (stddev = halo_radius/2, the painter's shadow
// mapping) at halo_alpha, under the stroke at stroke_alpha.
//
// Uses SetTarget round-trips on `ctx` — call OUTSIDE BeginDraw/EndDraw and
// re-bind the previous target afterwards (the painter-Prepare contract).
// Returns null on any soft failure (the presenter simply draws no glow).
Microsoft::WRL::ComPtr<ID2D1Bitmap1> BakeCameraGlowBitmap(
    ID2D1Factory1* factory, ID2D1DeviceContext* ctx, const std::string& shape,
    double corner_radius, int content_side, int padding_px, double strength);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GLOW_RENDERER_H_
