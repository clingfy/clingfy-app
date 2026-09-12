#include "Core/canvas_composition.h"

#include <algorithm>

#include "Capture/Export/export_geometry.h"

namespace clingfy::core {

double NormalizeToShortSide(double pixels, double reference_short_side) {
  // A degenerate reference means we do not yet know the canvas. Returning 0
  // renders an unpadded canvas rather than dividing by zero or producing an
  // absurd fraction that would clamp the content to nothing.
  if (!(reference_short_side > 0.0)) {
    return 0.0;
  }
  return std::max(0.0, pixels) / reference_short_side;
}

double DenormalizeFromShortSide(double fraction, double target_short_side) {
  if (!(target_short_side > 0.0)) {
    return 0.0;
  }
  return std::max(0.0, fraction) * target_short_side;
}

CanvasComposition MakeCanvasComposition(
    double padding_px, double corner_radius_px, double export_short_side,
    std::optional<std::int64_t> background_argb,
    std::wstring background_image_path) {
  CanvasComposition out{};
  out.padding_fraction = NormalizeToShortSide(padding_px, export_short_side);
  out.corner_radius_fraction =
      NormalizeToShortSide(corner_radius_px, export_short_side);
  // Kept so consumers that cannot use a fraction (the camera shadow preset is
  // an index, the bubble floor is a constant) can still resolve onto their own
  // surface. Non-positive stays 0 = "reference unknown", matching
  // NormalizeToShortSide's own degenerate contract.
  out.export_short_side = export_short_side > 0.0 ? export_short_side : 0.0;
  out.background_argb = background_argb;
  out.background_image_path = std::move(background_image_path);
  return out;
}

CanvasComposition ResolveCanvasComposition(const CanvasFramingArgs& framing,
                                           double source_w, double source_h) {
  CanvasComposition out{};
  // Backgrounds carry no length, so they resolve with or without a source.
  // Publishing them even while unresolved is what keeps the background visible
  // on the very first frame instead of one push behind.
  out.background_argb = framing.background_argb;
  out.background_image_path = framing.background_image_path;
  out.preset = framing.preset;
  out.has_preset = framing.has_preset;
  if (!(source_w > 0.0) || !(source_h > 0.0)) {
    // Source unknown: leave the lengths at 0 rather than normalising against a
    // guess. Re-resolving later is cheap; a wrong canvas baked into the first
    // frames is not.
    return out;
  }
  // ResolveTargetSize is the single source of truth for how a source plus
  // layout/resolution presets becomes an export canvas — the same function the
  // export itself calls, so the preview normalises against the canvas the
  // export will actually produce.
  const capture::export_::SizeF target = capture::export_::ResolveTargetSize(
      capture::export_::SizeF{source_w, source_h}, framing.layout_preset,
      framing.resolution_preset);
  const double export_short = std::min(target.width, target.height);
  out.padding_fraction =
      NormalizeToShortSide(framing.padding_px, export_short);
  out.corner_radius_fraction =
      NormalizeToShortSide(framing.corner_radius_px, export_short);
  out.export_short_side = export_short > 0.0 ? export_short : 0.0;
  return out;
}

bool CanvasNeedsReresolve(bool has_framing, unsigned int resolved_source_w,
                          unsigned int resolved_source_h,
                          unsigned int live_source_w,
                          unsigned int live_source_h) {
  if (!has_framing) {
    return false;
  }
  return resolved_source_w != live_source_w ||
         resolved_source_h != live_source_h;
}

}  // namespace clingfy::core
