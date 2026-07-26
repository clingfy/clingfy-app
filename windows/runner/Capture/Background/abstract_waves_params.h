// Deterministic parameter derivation for the "Graphic / Abstract Waves"
// procedural background.
//
// WHY THIS IS SPLIT FROM THE DRAWING
//
// The preset is DATA (palette, intensity, blur, seed); the bitmap is a cache.
// Every surface that draws a canvas -- live preview, export, and the preset
// thumbnail -- goes through the one platform compositor, so there is exactly one
// renderer per platform and no separate "baker" to drift from it.
//
// What CAN be shared exactly across platforms is the geometry, because it is
// driven by a seeded SplitMix64 stream. This header is the portable half: given
// the same seed and intensity it produces the same numbers macOS produces, so
// both platforms lay out the same waves in the same places. Only rasterization
// (antialiasing, gradient interpolation, blur kernel) differs.
//
// THE DRAW ORDER IS THE CONTRACT
//
// Parity depends on consuming the RNG in exactly macOS's order
// (AbstractWavesBackgroundRenderer.swift). Reordering these draws silently
// changes every generated background:
//
//   1  x  tilt                        (base gradient)
//   4  x  { baseline, amplitude,      (per ribbon, back to front)
//           phaseA, phaseB,
//           freqA, freqB }
//   2  x  { centerX, centerY,         (per highlight glow)
//           radius }
//   = 31 draws total
//
// COORDINATE SPACE
//
// Values here are FRACTIONS of the canvas, in macOS's bottom-left origin space
// (y increases upward), matching the Swift source they mirror. The Direct2D
// drawing flips to its top-left origin at use, keeping the flip in exactly one
// place instead of smeared through the maths.

#ifndef RUNNER_CAPTURE_BACKGROUND_ABSTRACT_WAVES_PARAMS_H_
#define RUNNER_CAPTURE_BACKGROUND_ABSTRACT_WAVES_PARAMS_H_

#include <cstdint>
#include <vector>

namespace clingfy::capture::background {

// SplitMix64, byte-identical to macOS `SeededGenerator`. Exposed so the parity
// tests can pin the raw stream, not just the derived values.
class SeededGenerator {
 public:
  explicit SeededGenerator(std::int64_t seed);

  std::uint64_t Next();
  // Uniform double in [lower, upper), matching the Swift `double(_:_:)`.
  double NextDouble(double lower, double upper);

 private:
  std::uint64_t state_;
};

struct WaveRibbonParams {
  double baseline_fraction = 0.0;   // of canvas height, from the BOTTOM
  double amplitude_fraction = 0.0;  // of canvas height
  double phase_a = 0.0;
  double phase_b = 0.0;
  double freq_a = 0.0;
  double freq_b = 0.0;
  double alpha = 0.0;      // final fill alpha, already clamped
  int palette_index = 0;   // which palette colour this ribbon uses
};

struct GlowParams {
  double center_x_fraction = 0.0;  // of canvas width
  double center_y_fraction = 0.0;  // of canvas height, from the BOTTOM
  double radius_fraction = 0.0;    // of min(width, height)
  double alpha = 0.0;
};

struct AbstractWavesParams {
  // Gradient axis tilt, as a fraction of height applied to the end point.
  double tilt = 0.0;
  std::vector<WaveRibbonParams> ribbons;
  std::vector<GlowParams> glows;
};

inline constexpr int kWaveRibbonCount = 4;
inline constexpr int kWaveGlowCount = 2;

// Derive every parameter for one preset. `intensity` is clamped to [0,1] the
// same way macOS clamps it. `palette_size` selects ribbon colours modulo the
// palette, matching `colors[(index + 1) % colors.count]`.
AbstractWavesParams DeriveAbstractWavesParams(std::int64_t seed,
                                              double intensity,
                                              int palette_size);

// Sample the ribbon's wave at normalized position `t` in [0,1], returning the
// offset from the baseline in canvas-height fractions. Same two-sine sum macOS
// uses; shared so the drawing and any test agree on the curve.
double SampleRibbonWave(const WaveRibbonParams& ribbon, double t);

// Gaussian sigma for the softening pass, in pixels. macOS skips the blur
// entirely below 0.5, so this returns 0 there and the caller draws unblurred.
double ResolveBlurSigma(double blur, double canvas_width, double canvas_height);

}  // namespace clingfy::capture::background

#endif  // RUNNER_CAPTURE_BACKGROUND_ABSTRACT_WAVES_PARAMS_H_
