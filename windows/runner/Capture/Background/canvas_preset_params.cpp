#include "Capture/Background/canvas_preset_params.h"

#include <algorithm>

#include "Capture/Background/abstract_waves_params.h"

namespace clingfy::capture::background {

namespace {

double ClampUnit(double v) { return std::min(std::max(v, 0.0), 1.0); }

}  // namespace

GraphicMeshParams DeriveGraphicMeshParams(std::int64_t seed, double intensity,
                                          int palette_size) {
  GraphicMeshParams params;
  if (palette_size <= 0) return params;

  SeededGenerator rng(seed);
  const double clamped = ClampUnit(intensity);
  // macOS: max(6, colors.count + 2). Never fewer than 6 or the mesh reads as a
  // handful of discrete circles rather than a blended field.
  const int blob_count = std::max(6, palette_size + 2);
  // Capped at 0.95 on macOS: a fully opaque blob would erase everything drawn
  // under it, collapsing the mesh into flat colour.
  const double alpha = std::min(0.40 + 0.45 * clamped, 0.95);

  params.blobs.reserve(static_cast<size_t>(blob_count));
  for (int index = 0; index < blob_count; ++index) {
    MeshBlobParams blob;
    // Draw order is the contract — x, then y, then radius.
    blob.center_x_fraction = rng.NextDouble(-0.1, 1.1);
    blob.center_y_fraction = rng.NextDouble(-0.1, 1.1);
    blob.radius_fraction = rng.NextDouble(0.45, 0.95);
    blob.alpha = alpha;
    blob.palette_index = (index + 1) % palette_size;
    params.blobs.push_back(blob);
  }
  return params;
}

RadialGlowParams DeriveRadialGlowParams(std::int64_t seed, double intensity,
                                        int palette_size) {
  RadialGlowParams params;
  if (palette_size <= 0) return params;

  SeededGenerator rng(seed);
  const double clamped = ClampUnit(intensity);
  const int glow_count = 3;
  // Much fainter than the mesh blobs: these sit ON TOP of a full-strength
  // diagonal gradient, and this preset is meant to read as the calm one.
  const double alpha = 0.10 + 0.28 * clamped;

  params.glows.reserve(static_cast<size_t>(glow_count));
  for (int index = 0; index < glow_count; ++index) {
    RadialGlowSpotParams glow;
    // Same draw order as the mesh: x, y, radius. Centres stay inside
    // [0.15, 0.85] so a glow never hugs an edge.
    glow.center_x_fraction = rng.NextDouble(0.15, 0.85);
    glow.center_y_fraction = rng.NextDouble(0.15, 0.85);
    glow.radius_fraction = rng.NextDouble(0.4, 0.8);
    glow.alpha = alpha;
    // macOS walks the palette backwards from the lightest colour, so the glows
    // are the bright end of the ramp rather than the dark base.
    glow.palette_index = (palette_size - 1 - (index % palette_size));
    params.glows.push_back(glow);
  }
  return params;
}

}  // namespace clingfy::capture::background
