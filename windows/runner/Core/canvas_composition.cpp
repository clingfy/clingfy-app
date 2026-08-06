#include "Core/canvas_composition.h"

#include <algorithm>

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

}  // namespace clingfy::core
