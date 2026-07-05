#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_STYLE_STORE_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_STYLE_STORE_H_

#include <cstdint>
#include <mutex>
#include <string>

#include "Capture/Camera/camera_bubble_painter.h"

// Live camera-overlay styling for the recording preview (Phase: editing port —
// live-styled camera parity with macOS).
//
// The Dart recording sidebar drives the camera bubble's look through a family of
// granular `setCameraOverlay*` / `setChromaKey*` / `setOverlayMirror` method
// calls (see lib/app/home/overlay/overlay_controller.dart). On macOS these
// update a live NSWindow overlay; on Windows they used to be no-ops, so the live
// preview always showed a raw rectangle. This store is the missing native state:
// the bridge handlers write each setting here, and the live camera compositor
// reads a Snapshot() per frame to draw the SAME styled bubble the export /
// inline-preview draw through the shared CameraBubblePainter — WYSIWYG.
//
// Wire contract (keep in sync with overlay_controller.dart):
//   setCameraOverlayShape       {shapeId:int}     OverlayShape.wireValue
//   setCameraOverlayRoundness   {roundness:double} 0.0..0.4 corner fraction
//   setCameraOverlayOpacity     {opacity:double}   0..1
//   setCameraOverlayShadow      {shadow:int}       OverlayShadow index (0..3)
//   setCameraOverlayBorder      {border:int}       OverlayBorder index (0..5)
//   setCameraOverlayBorderWidth {width:double}     canvas px at bubble scale
//   setCameraOverlayBorderColor {color:int}        ARGB
//   setOverlayMirror            {mirrored:bool}
//   setChromaKeyEnabled         {enabled:bool}
//   setChromaKeyStrength        {strength:double}  0..1 tolerance
//   setChromaKeyColor           {color:int}        ARGB
namespace clingfy::capture {

// Plain snapshot of the live overlay style. Defaults mirror the Dart defaults so
// a snapshot taken before any setter fires renders a sane bubble.
struct CameraOverlayLiveStyle {
  int shape_wire = 5;  // OverlayShape.squircle (Dart defaultValue).
  double roundness = 0.0;
  double opacity = 1.0;
  int shadow_index = 0;  // OverlayShadow.none
  int border_index = 0;  // OverlayBorder.none
  double border_width = 0.0;
  std::uint32_t border_argb = 0;
  bool mirror = false;
  bool chroma_enabled = false;
  double chroma_strength = 0.4;
  std::uint32_t chroma_argb = 0xFF00FF00;  // default green
};

// Resolved painter inputs for one style snapshot. Pure translation of the live
// wire model into the CameraBubblePainter contract, so it is unit-testable
// without any D2D device.
struct ResolvedBubbleStyle {
  std::string shape;         // CameraShape name understood by the painter.
  double corner_radius = 0;  // 0..0.5 fraction.
  std::string content_mode;  // "fill" (cover) — the live overlay always covers.
  CameraBubblePainter::Style style;
};

// Map the live wire style to painter inputs. hexagon/star have no
// CameraBubblePainter geometry, so they fall back to the nearest supported shape
// (documented parity gap); everything else maps 1:1.
ResolvedBubbleStyle ResolveOverlayBubbleStyle(const CameraOverlayLiveStyle& s);

// Map an OverlayShape.wireValue to the painter's CameraShape name. Exposed for
// tests and reuse by the floating window's region builder.
std::string OverlayShapeToPainterShape(int shape_wire);

// Thread-safe holder. Setters run on the platform thread (bridge handlers);
// Snapshot() runs on the camera capture / compositor thread.
class CameraOverlayStyleStore {
 public:
  // Directly constructible so unit tests get an isolated instance; production
  // code shares the process-wide Instance().
  CameraOverlayStyleStore() = default;

  static CameraOverlayStyleStore& Instance();

  void SetShape(int shape_wire);
  void SetRoundness(double roundness);
  void SetOpacity(double opacity);
  void SetShadow(int shadow_index);
  void SetBorder(int border_index);
  void SetBorderWidth(double width);
  void SetBorderColor(std::uint32_t argb);
  void SetMirror(bool mirror);
  void SetChromaEnabled(bool enabled);
  void SetChromaStrength(double strength);
  void SetChromaColor(std::uint32_t argb);

  // A consistent copy of the current style.
  CameraOverlayLiveStyle Snapshot() const;

  // Monotonic counter bumped on every mutation, so the compositor can cheaply
  // detect "did anything change since I last rebuilt the painter?" without
  // comparing every field.
  std::uint64_t revision() const;

 private:
  mutable std::mutex mutex_;
  CameraOverlayLiveStyle style_;
  std::uint64_t revision_ = 0;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_STYLE_STORE_H_
