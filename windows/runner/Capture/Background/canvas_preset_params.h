// Pure geometry for the `graphicMesh` and `radialGlow` canvas presets.
//
// Same split as `abstract_waves_params.h`: everything that decides WHERE the
// shapes go is a pure function of (seed, intensity, palette size), so it can be
// tested without a GPU, and the Direct2D file only draws what it is handed.
//
// The RNG DRAW ORDER in each Derive function is a cross-platform contract, not
// an implementation detail. macOS consumes its SeededGenerator in a fixed
// order, and the same seed must place the same blob in the same spot on both
// platforms — reordering or inserting a draw silently changes every rendered
// background for every existing project. The tests pin the draw counts.

#ifndef RUNNER_CAPTURE_BACKGROUND_CANVAS_PRESET_PARAMS_H_
#define RUNNER_CAPTURE_BACKGROUND_CANVAS_PRESET_PARAMS_H_

#include <cstdint>
#include <vector>

namespace clingfy::capture::background {

// One soft radial blob. Positions are FRACTIONS of the canvas so the same
// params render identically at thumbnail and export sizes.
struct MeshBlobParams {
  // Deliberately allowed outside [0,1]: macOS scatters centres over
  // [-0.1, 1.1] so blobs bleed off the edges instead of forming a visible
  // ring of circles inside the frame.
  double center_x_fraction = 0.0;
  double center_y_fraction = 0.0;
  double radius_fraction = 0.0;  // of the canvas SHORT side
  double alpha = 0.0;            // inner alpha, already clamped
  int palette_index = 0;
};

struct GraphicMeshParams {
  std::vector<MeshBlobParams> blobs;
};

// One concentric glow over the radialGlow base gradient.
struct RadialGlowSpotParams {
  double center_x_fraction = 0.0;
  double center_y_fraction = 0.0;
  double radius_fraction = 0.0;  // of the canvas SHORT side
  double alpha = 0.0;
  int palette_index = 0;
};

struct RadialGlowParams {
  std::vector<RadialGlowSpotParams> glows;
};

// macOS: blobCount = max(6, colors.count + 2); each blob draws x, y, radius in
// that order, and takes colour (index + 1) % count so the base fill colour is
// not immediately repainted over itself.
GraphicMeshParams DeriveGraphicMeshParams(std::int64_t seed, double intensity,
                                          int palette_size);

// macOS: exactly 3 glows, each drawing x, y, radius, and walking the palette
// BACKWARDS from the lightest colour.
RadialGlowParams DeriveRadialGlowParams(std::int64_t seed, double intensity,
                                        int palette_size);

}  // namespace clingfy::capture::background

#endif  // RUNNER_CAPTURE_BACKGROUND_CANVAS_PRESET_PARAMS_H_
