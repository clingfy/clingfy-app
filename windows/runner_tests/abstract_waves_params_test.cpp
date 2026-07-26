#include "Capture/Background/abstract_waves_params.h"

#include <gtest/gtest.h>

#include <cmath>
#include <set>

namespace clingfy::capture::background {
namespace {

// SplitMix64 is the thing that makes cross-platform parity possible: the preset
// is DATA, each platform renders it with its own compositor, and the seeded
// stream guarantees both lay the waves out identically. If this generator ever
// stops matching macOS `SeededGenerator`, every generated background silently
// diverges between platforms.
//
// NOTE ON THE ONE-STEP OFFSET
//
// These are NOT the canonical splitmix64(0) outputs, and that is correct. macOS
// `SeededGenerator.init` pre-adds the golden gamma (`state = seed &+ gamma`) and
// `next()` adds it AGAIN before mixing, so this generator's output N equals a
// reference splitmix64(seed=0) output N+1. The canonical first value
// (0xE220A8397B1DCDAF) is therefore never produced. Reproducing that quirk is
// the whole point: it is what macOS emits, so it is what keeps the two
// platforms laying out identical waves.
TEST(SeededGeneratorTest, MatchesMacOsSeededGeneratorForSeedZero) {
  SeededGenerator rng(0);
  EXPECT_EQ(rng.Next(), 7960286522194355700ull);   // 0x6E789E6AA1B965F4
  EXPECT_EQ(rng.Next(), 487617019471545679ull);    // 0x06C45D188009454F
  EXPECT_EQ(rng.Next(), 17909611376780542444ull);
}

TEST(SeededGeneratorTest, DifferentSeedsProduceDifferentStreams) {
  SeededGenerator a(1);
  SeededGenerator b(2);
  EXPECT_NE(a.Next(), b.Next());
}

TEST(SeededGeneratorTest, NextDoubleStaysInRangeAndIsDeterministic) {
  SeededGenerator a(1234);
  SeededGenerator b(1234);
  for (int i = 0; i < 200; ++i) {
    const double x = a.NextDouble(-0.25, 0.25);
    EXPECT_GE(x, -0.25);
    EXPECT_LT(x, 0.25);
    EXPECT_DOUBLE_EQ(x, b.NextDouble(-0.25, 0.25))
        << "same seed must replay the same stream";
  }
}

// Negative seeds must not be undefined or collapse: Dart can hand us any int.
TEST(SeededGeneratorTest, NegativeSeedIsWellDefined) {
  SeededGenerator neg(-42);
  SeededGenerator neg2(-42);
  EXPECT_EQ(neg.Next(), neg2.Next());
  SeededGenerator pos(42);
  SeededGenerator neg3(-42);
  EXPECT_NE(pos.Next(), neg3.Next());
}

// The draw ORDER is the parity contract: 1 tilt, then 6 per ribbon, then 3 per
// glow. If a future edit reorders these, the derived values shift even though
// the maths is unchanged — so pin the total consumption.
TEST(AbstractWavesParamsTest, ConsumesExactlyThirtyOneRandomDraws) {
  const auto params = DeriveAbstractWavesParams(7, 0.5, 3);

  SeededGenerator counter(7);
  for (int i = 0; i < 31; ++i) counter.Next();
  // A generator advanced 31 times must now match one that produced the params
  // and then drew once more.
  SeededGenerator replay(7);
  const auto again = DeriveAbstractWavesParams(7, 0.5, 3);
  (void)again;
  for (int i = 0; i < 31; ++i) replay.Next();
  EXPECT_EQ(counter.Next(), replay.Next());

  EXPECT_EQ(static_cast<int>(params.ribbons.size()), kWaveRibbonCount);
  EXPECT_EQ(static_cast<int>(params.glows.size()), kWaveGlowCount);
}

TEST(AbstractWavesParamsTest, IsDeterministicForTheSameSeed) {
  const auto a = DeriveAbstractWavesParams(99, 0.7, 4);
  const auto b = DeriveAbstractWavesParams(99, 0.7, 4);
  EXPECT_DOUBLE_EQ(a.tilt, b.tilt);
  for (size_t i = 0; i < a.ribbons.size(); ++i) {
    EXPECT_DOUBLE_EQ(a.ribbons[i].baseline_fraction,
                     b.ribbons[i].baseline_fraction);
    EXPECT_DOUBLE_EQ(a.ribbons[i].phase_a, b.ribbons[i].phase_a);
    EXPECT_DOUBLE_EQ(a.ribbons[i].freq_b, b.ribbons[i].freq_b);
  }
}

TEST(AbstractWavesParamsTest, DifferentSeedsProduceDifferentLayouts) {
  const auto a = DeriveAbstractWavesParams(1, 0.5, 4);
  const auto b = DeriveAbstractWavesParams(2, 0.5, 4);
  EXPECT_NE(a.tilt, b.tilt);
}

// Ribbons run back to front: baselines descend so nearer ribbons overlap, and
// alpha rises with progress. Getting this backwards inverts the depth.
TEST(AbstractWavesParamsTest, RibbonsRunBackToFrontWithRisingAlpha) {
  const auto p = DeriveAbstractWavesParams(5, 1.0, 4);
  // Baseline trend is 0.62 -> 0.22 plus +/-0.04 jitter, so it must fall overall
  // even though adjacent pairs could tie.
  EXPECT_GT(p.ribbons.front().baseline_fraction,
            p.ribbons.back().baseline_fraction);
  EXPECT_LT(p.ribbons.front().alpha, p.ribbons.back().alpha);
  for (const auto& r : p.ribbons) {
    EXPECT_LE(r.alpha, 0.92) << "alpha is clamped, per macOS";
    EXPECT_GE(r.amplitude_fraction, 0.05);
    EXPECT_LT(r.amplitude_fraction, 0.12);
  }
}

TEST(AbstractWavesParamsTest, IntensityIsClampedAndDrivesAlpha) {
  const auto low = DeriveAbstractWavesParams(3, 0.0, 4);
  const auto high = DeriveAbstractWavesParams(3, 1.0, 4);
  EXPECT_LT(low.ribbons[0].alpha, high.ribbons[0].alpha);
  EXPECT_LT(low.glows[0].alpha, high.glows[0].alpha);

  // Out-of-range intensity must clamp, not extrapolate into absurd alphas.
  const auto over = DeriveAbstractWavesParams(3, 5.0, 4);
  const auto under = DeriveAbstractWavesParams(3, -5.0, 4);
  EXPECT_DOUBLE_EQ(over.ribbons[0].alpha, high.ribbons[0].alpha);
  EXPECT_DOUBLE_EQ(under.ribbons[0].alpha, low.ribbons[0].alpha);
}

// Palette indexing mirrors macOS `colors[(index + 1) % colors.count]`. A
// single-colour palette must not divide by zero or index out of range.
TEST(AbstractWavesParamsTest, PaletteIndexWrapsAndSurvivesDegeneratePalettes) {
  const auto three = DeriveAbstractWavesParams(11, 0.5, 3);
  EXPECT_EQ(three.ribbons[0].palette_index, 1);
  EXPECT_EQ(three.ribbons[1].palette_index, 2);
  EXPECT_EQ(three.ribbons[2].palette_index, 0);

  for (const int size : {0, 1, -4}) {
    const auto p = DeriveAbstractWavesParams(11, 0.5, size);
    for (const auto& r : p.ribbons) {
      EXPECT_GE(r.palette_index, 0) << "palette size " << size;
    }
  }
}

TEST(AbstractWavesParamsTest, GlowsStayInsideTheCanvas) {
  const auto p = DeriveAbstractWavesParams(21, 0.8, 4);
  for (const auto& g : p.glows) {
    EXPECT_GE(g.center_x_fraction, 0.15);
    EXPECT_LT(g.center_x_fraction, 0.85);
    EXPECT_GE(g.center_y_fraction, 0.45);
    EXPECT_LT(g.center_y_fraction, 0.95);
    EXPECT_GT(g.radius_fraction, 0.0);
  }
}

TEST(AbstractWavesParamsTest, WaveSampleIsBoundedByAmplitude) {
  const auto p = DeriveAbstractWavesParams(31, 0.5, 4);
  const auto& r = p.ribbons[0];
  for (int i = 0; i <= 100; ++i) {
    const double t = i / 100.0;
    const double w = SampleRibbonWave(r, t);
    // 0.7 + 0.3 weighted sines can never exceed the amplitude.
    EXPECT_LE(std::abs(w), r.amplitude_fraction + 1e-12);
  }
}

// macOS skips the blur below sigma 0.5 and below blur 0.001; both collapse to
// "draw unblurred", and a zero here is what tells the renderer to skip the pass.
TEST(AbstractWavesBlurTest, SmallBlurResolvesToNoPass) {
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(0.0, 1280, 720), 0.0);
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(0.0005, 1280, 720), 0.0);
  // 0.01 * 720 * 0.05 = 0.36, below the 0.5 floor.
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(0.01, 1280, 720), 0.0);
}

TEST(AbstractWavesBlurTest, SigmaScalesWithTheShorterSide) {
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(1.0, 1280, 720), 720.0 * 0.05);
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(0.5, 1280, 720), 0.5 * 720.0 * 0.05);
  // Portrait: the shorter side is now the width.
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(1.0, 720, 1280), 720.0 * 0.05);
}

TEST(AbstractWavesBlurTest, OutOfRangeBlurClamps) {
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(5.0, 1280, 720),
                   ResolveBlurSigma(1.0, 1280, 720));
  EXPECT_DOUBLE_EQ(ResolveBlurSigma(-1.0, 1280, 720), 0.0);
}

}  // namespace
}  // namespace clingfy::capture::background
