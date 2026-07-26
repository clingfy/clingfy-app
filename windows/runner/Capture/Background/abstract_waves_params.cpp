#include "Capture/Background/abstract_waves_params.h"

#include <algorithm>
#include <cmath>

namespace clingfy::capture::background {

namespace {

constexpr std::uint64_t kGoldenGamma = 0x9E3779B97F4A7C15ull;
// 2^53, matching the Swift `1.0 / 9_007_199_254_740_992.0`.
constexpr double kTwoPow53 = 9007199254740992.0;
constexpr double kPi = 3.14159265358979323846;

}  // namespace

SeededGenerator::SeededGenerator(std::int64_t seed)
    : state_(static_cast<std::uint64_t>(seed) + kGoldenGamma) {}

std::uint64_t SeededGenerator::Next() {
  state_ += kGoldenGamma;
  std::uint64_t z = state_;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

double SeededGenerator::NextDouble(double lower, double upper) {
  const double unit = static_cast<double>(Next() >> 11) * (1.0 / kTwoPow53);
  return lower + unit * (upper - lower);
}

AbstractWavesParams DeriveAbstractWavesParams(std::int64_t seed,
                                              double intensity,
                                              int palette_size) {
  AbstractWavesParams out{};
  SeededGenerator rng(seed);
  const double clamped_intensity = std::min(std::max(intensity, 0.0), 1.0);
  const int palette = std::max(1, palette_size);

  // --- 1. Base gradient tilt (draw #1) ---
  out.tilt = rng.NextDouble(-0.25, 0.25);

  // --- 2. Wave ribbons, back to front (draws #2..#25) ---
  out.ribbons.reserve(kWaveRibbonCount);
  for (int index = 0; index < kWaveRibbonCount; ++index) {
    const double progress =
        static_cast<double>(index) / static_cast<double>(kWaveRibbonCount - 1);

    WaveRibbonParams r{};
    // Order matters: baseline then amplitude are drawn in drawWaveRibbons,
    // then the four wave terms inside drawWaveRibbon.
    r.baseline_fraction = 0.62 - 0.40 * progress + rng.NextDouble(-0.04, 0.04);
    r.amplitude_fraction = rng.NextDouble(0.05, 0.12);
    r.phase_a = rng.NextDouble(0.0, 2.0 * kPi);
    r.phase_b = rng.NextDouble(0.0, 2.0 * kPi);
    r.freq_a = rng.NextDouble(1.1, 2.3);
    r.freq_b = rng.NextDouble(2.6, 4.6);

    r.palette_index = (index + 1) % palette;
    const double alpha =
        (0.22 + 0.30 * clamped_intensity) * (0.78 + 0.22 * progress);
    r.alpha = std::min(alpha, 0.92);

    out.ribbons.push_back(r);
  }

  // --- 3. Highlight glows (draws #26..#31) ---
  out.glows.reserve(kWaveGlowCount);
  for (int i = 0; i < kWaveGlowCount; ++i) {
    GlowParams g{};
    g.center_x_fraction = rng.NextDouble(0.15, 0.85);
    g.center_y_fraction = rng.NextDouble(0.45, 0.95);
    g.radius_fraction = rng.NextDouble(0.35, 0.65);
    g.alpha = 0.06 + 0.14 * clamped_intensity;
    out.glows.push_back(g);
  }

  return out;
}

double SampleRibbonWave(const WaveRibbonParams& ribbon, double t) {
  return ribbon.amplitude_fraction * 0.7 *
             std::sin(ribbon.phase_a + t * ribbon.freq_a * 2.0 * kPi) +
         ribbon.amplitude_fraction * 0.3 *
             std::sin(ribbon.phase_b + t * ribbon.freq_b * 2.0 * kPi);
}

double ResolveBlurSigma(double blur, double canvas_width,
                        double canvas_height) {
  const double clamped = std::min(std::max(blur, 0.0), 1.0);
  // macOS bails out below 0.001 before even building the image, then again
  // below sigma 0.5 — both collapse to "no blur", so one gate covers it.
  if (!(clamped > 0.001)) return 0.0;
  const double sigma =
      clamped * std::min(canvas_width, canvas_height) * 0.05;
  return sigma > 0.5 ? sigma : 0.0;
}

}  // namespace clingfy::capture::background
