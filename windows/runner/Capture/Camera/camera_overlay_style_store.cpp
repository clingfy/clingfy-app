#include "Capture/Camera/camera_overlay_style_store.h"

#include <algorithm>
#include <cmath>

#include "Capture/Camera/camera_export_layout.h"

namespace clingfy::capture {

namespace {

// OverlayShadow index (Dart: none, light, medium, strong) maps straight onto the
// painter's shadow_preset numbering (ResolveCameraShadowStyle). Clamp defensively
// so a forward-compatible Dart enum can't index past the painter's table.
int ClampShadowPreset(int shadow_index) {
  return std::clamp(shadow_index, 0, 3);
}

}  // namespace

std::string OverlayShapeToPainterShape(int shape_wire) {
  // OverlayShape.wireValue: circle(0) roundedRect(1) square(2) hexagon(3)
  // star(4) squircle(5). The CameraBubblePainter only has circle / roundedRect /
  // square / squircle geometry, so hexagon and star fall back to the nearest
  // supported shape (a documented Windows parity gap — see docs/windows-port.md).
  switch (shape_wire) {
    case 0:
      return "circle";
    case 1:
      return "roundedRect";
    case 2:
      return "square";
    case 3:            // hexagon → squircle (closest rounded silhouette)
      return "squircle";
    case 4:            // star → circle (no polygon geometry; keep it round)
      return "circle";
    case 5:
    default:
      return "squircle";
  }
}

InscribedSquare CameraOverlayInscribedSquare(int w, int h) {
  const int side = std::min(w, h);
  return InscribedSquare{(w - side) / 2, (h - side) / 2, side};
}

double ComputeCameraEffectPadding(const CameraOverlayLiveStyle& s) {
  const bool border_on = s.border_index != 0 && s.border_width > 0.0;
  const double border_out = border_on ? s.border_width : 0.0;

  double shadow_out = 0.0;
  const CameraShadowStyle sh =
      ResolveCameraShadowStyle(ClampShadowPreset(s.shadow_index));
  if (sh.enabled) {
    // PrepareShadow's bake extent beyond the content square: 3 stddevs of the
    // Gaussian (stddev = blur/2) + bw/2 + 2, shifted by the preset offset.
    const double stddev = sh.blur_radius * 0.5;
    shadow_out = std::ceil(stddev * 3.0) + border_out / 2.0 + 2.0 +
                 std::max(std::abs(sh.offset_x), std::abs(sh.offset_y));
  }

  double glow_out = 0.0;
  if (s.glow_enabled) {
    const double gs = std::clamp(s.glow_strength, 0.10, 1.00);
    const double line_width = 3.0 + 7.0 * gs;
    const double halo_radius = 6.0 + 20.0 * gs;
    glow_out = line_width + 2.0 * halo_radius + 6.0;
  }

  return std::ceil(std::max({border_out, shadow_out, glow_out, 12.0}));
}

ResolvedBubbleStyle ResolveOverlayBubbleStyle(const CameraOverlayLiveStyle& s) {
  ResolvedBubbleStyle r;
  r.shape = OverlayShapeToPainterShape(s.shape_wire);
  r.corner_radius = std::clamp(s.roundness, 0.0, 0.5);
  r.content_mode = "fill";  // the live overlay always covers the bubble.

  CameraBubblePainter::Style style;
  style.mirror = s.mirror;
  style.opacity = std::clamp(s.opacity, 0.0, 1.0);

  // Border: only when a preset is selected (OverlayBorder.none == 0). The color
  // is supplied separately by Dart and already resolved to the preset color for
  // the named presets, so a non-none border always carries a usable ARGB.
  const bool border_on = s.border_index != 0 && s.border_width > 0.0;
  style.border_width = border_on ? s.border_width : 0.0;
  style.has_border_color = border_on;
  style.border_argb = s.border_argb;

  style.shadow_preset = ClampShadowPreset(s.shadow_index);

  style.chroma_enabled = s.chroma_enabled;
  style.chroma_strength = std::clamp(s.chroma_strength, 0.0, 1.0);
  style.has_chroma_color = true;
  style.chroma_argb = s.chroma_argb;

  r.style = style;
  return r;
}

CameraOverlayStyleStore& CameraOverlayStyleStore::Instance() {
  static CameraOverlayStyleStore instance;
  return instance;
}

void CameraOverlayStyleStore::SetShape(int shape_wire) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.shape_wire = shape_wire;
  ++revision_;
}

void CameraOverlayStyleStore::SetRoundness(double roundness) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.roundness = roundness;
  ++revision_;
}

void CameraOverlayStyleStore::SetOpacity(double opacity) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.opacity = opacity;
  ++revision_;
}

void CameraOverlayStyleStore::SetShadow(int shadow_index) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.shadow_index = shadow_index;
  ++revision_;
}

void CameraOverlayStyleStore::SetBorder(int border_index) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.border_index = border_index;
  ++revision_;
}

void CameraOverlayStyleStore::SetBorderWidth(double width) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.border_width = width;
  ++revision_;
}

void CameraOverlayStyleStore::SetBorderColor(std::uint32_t argb) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.border_argb = argb;
  ++revision_;
}

void CameraOverlayStyleStore::SetMirror(bool mirror) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.mirror = mirror;
  ++revision_;
}

void CameraOverlayStyleStore::SetChromaEnabled(bool enabled) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.chroma_enabled = enabled;
  ++revision_;
}

void CameraOverlayStyleStore::SetChromaStrength(double strength) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.chroma_strength = strength;
  ++revision_;
}

void CameraOverlayStyleStore::SetChromaColor(std::uint32_t argb) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.chroma_argb = argb;
  ++revision_;
}

void CameraOverlayStyleStore::SetGlowEnabled(bool enabled) {
  std::lock_guard<std::mutex> lock(mutex_);
  style_.glow_enabled = enabled;
  ++revision_;
}

void CameraOverlayStyleStore::SetGlowStrength(double strength) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Mirror the macOS facade clamp (0.10..1.00) at the store boundary so every
  // presenter reads a sane value.
  style_.glow_strength = std::clamp(strength, 0.10, 1.00);
  ++revision_;
}

CameraOverlayLiveStyle CameraOverlayStyleStore::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return style_;
}

std::uint64_t CameraOverlayStyleStore::revision() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return revision_;
}

}  // namespace clingfy::capture
