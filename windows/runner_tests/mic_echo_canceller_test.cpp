#include "Audio/EchoCancel/mic_echo_canceller.h"

#include <gtest/gtest.h>

#include <cmath>
#include <random>
#include <vector>

// A canceller can only be tested deterministically against SYNTHETIC signals:
// build a mic that is a known delayed, attenuated copy of a known system track
// and assert the bleed comes out. Real recordings would make these flaky and
// prove less.
//
// The properties that matter, and the audible failure each one guards:
//   * bleed is actually reduced                     — the feature works at all
//   * an independent mic is left ALONE              — headphones must be
//     bit-exact; a canceller that "cleans" a clean mic damages every recording
//   * near-end voice survives double-talk           — the failure that forced
//     macOS through algorithm versions 4 and 6 (voice gutted / distorted)
//   * a silent reference cannot destabilise it      — version 5 (loud
//     out-of-scale bursts after adapting on silence)
namespace clingfy::audio::echo {
namespace {

constexpr int kRate = 48000;

double Rms(const std::vector<float>& x, size_t from = 0) {
  if (x.size() <= from) return 0.0;
  double s = 0.0;
  for (size_t i = from; i < x.size(); ++i) s += static_cast<double>(x[i]) * x[i];
  return std::sqrt(s / static_cast<double>(x.size() - from));
}

// Deterministic broadband "system audio" — a seeded PRNG, so every run of
// these tests sees the same signal.
std::vector<float> Noise(int samples, unsigned seed, float amplitude = 0.3f) {
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> dist(-amplitude, amplitude);
  std::vector<float> out(static_cast<size_t>(samples));
  for (float& v : out) v = dist(rng);
  return out;
}

// A tone stands in for the user's voice: strongly present, and uncorrelated
// with the noise reference, which is exactly what the voice detector keys on.
std::vector<float> Tone(int samples, double hz, float amplitude) {
  std::vector<float> out(static_cast<size_t>(samples));
  for (int i = 0; i < samples; ++i) {
    out[static_cast<size_t>(i)] =
        amplitude * static_cast<float>(std::sin(2.0 * 3.14159265358979 * hz *
                                                i / kRate));
  }
  return out;
}

// mic = bleed(system delayed by `delay`, scaled by `coupling`) + near_end.
std::vector<float> MakeMic(const std::vector<float>& system, int delay,
                           float coupling,
                           const std::vector<float>& near_end) {
  std::vector<float> mic(system.size(), 0.0f);
  for (size_t i = 0; i < system.size(); ++i) {
    const int j = static_cast<int>(i) - delay;
    if (j >= 0) mic[i] += coupling * system[static_cast<size_t>(j)];
    if (i < near_end.size()) mic[i] += near_end[i];
  }
  return mic;
}

// --- the no-op cases, which are the ones that must never regress ------------

TEST(MicEchoCancellerTest, HeadphonesAreLeftExactlyAsRecorded) {
  // Independent signals: no bleed exists, so the mic must come back byte for
  // byte. A canceller that touches a clean mic damages every headphone user's
  // recording, which is most of them.
  const auto system = Noise(kRate * 2, 1);
  const auto mic = Noise(kRate * 2, 999);
  const auto result = CancelEcho(mic, system);
  EXPECT_FALSE(result.applied);
  ASSERT_EQ(result.mic.size(), mic.size());
  for (size_t i = 0; i < mic.size(); ++i) {
    EXPECT_FLOAT_EQ(result.mic[i], mic[i]) << "diverged at " << i;
  }
}

TEST(MicEchoCancellerTest, SilentSystemIsANoOp) {
  const auto system = std::vector<float>(kRate * 2, 0.0f);
  const auto mic = Tone(kRate * 2, 220.0, 0.2f);
  const auto result = CancelEcho(mic, system);
  EXPECT_FALSE(result.applied);
  EXPECT_EQ(result.mic, mic);
}

TEST(MicEchoCancellerTest, TooShortToEstimateIsANoOp) {
  // Under 0.1 s there is not enough signal to estimate a delay; guessing would
  // be worse than doing nothing.
  const auto system = Noise(1000, 3);
  const auto mic = Noise(1000, 4);
  const auto result = CancelEcho(mic, system);
  EXPECT_FALSE(result.applied);
  EXPECT_EQ(result.mic.size(), mic.size());
}

TEST(MicEchoCancellerTest, EmptyInputsDoNotCrash) {
  const auto result = CancelEcho({}, {});
  EXPECT_FALSE(result.applied);
  EXPECT_TRUE(result.mic.empty());
}

// --- the cancelling case ----------------------------------------------------

TEST(MicEchoCancellerTest, PureBleedIsDetectedAndReduced) {
  // The pause case: system playing, user silent, so the mic is bleed only.
  // This is where the echo is exposed and audible once mic gain is applied.
  const int n = kRate * 3;
  const auto system = Noise(n, 7);
  const int delay = static_cast<int>(0.060 * kRate);  // 60 ms round trip
  const auto mic = MakeMic(system, delay, 0.25f, {});

  const auto result = CancelEcho(mic, system);
  ASSERT_TRUE(result.applied) << "bleed was not detected at all";
  EXPECT_GT(std::abs(result.bleed_correlation), kGateCorrelation);
  // The estimated delay should land near the real one (decimation by 8 makes
  // this coarse, hence the tolerance).
  EXPECT_NEAR(result.delay_ms, 60.0, 5.0);

  // Skip the filter's convergence region before measuring.
  const size_t settle = static_cast<size_t>(kRate);
  EXPECT_LT(Rms(result.mic, settle), Rms(mic, settle) * 0.6)
      << "bleed was not meaningfully reduced";
}

TEST(MicEchoCancellerTest, ReportsAReductionForRealBleed) {
  const int n = kRate * 3;
  const auto system = Noise(n, 11);
  const auto mic = MakeMic(system, static_cast<int>(0.05 * kRate), 0.3f, {});
  const auto result = CancelEcho(mic, system);
  ASSERT_TRUE(result.applied);
  EXPECT_LT(result.reduction_db, 0.0) << "residual should be below the original";
}

// --- double talk: the case that broke macOS twice ---------------------------

TEST(MicEchoCancellerTest, NearEndVoiceSurvivesDoubleTalk) {
  // User speaks OVER the system audio. The bleed is masked by the speech at
  // every gain, so it does not need cancelling — and must not be, because
  // subtracting a filter estimate there damages the voice. macOS shipped this
  // wrong twice (v4 gutted the voice, v6 distorted it on quiet recordings).
  const int n = kRate * 3;
  const auto system = Noise(n, 13);
  const auto voice = Tone(n, 180.0, 0.25f);  // well above the voice floor
  const auto mic = MakeMic(system, static_cast<int>(0.06 * kRate), 0.2f, voice);

  const auto result = CancelEcho(mic, system);
  ASSERT_EQ(result.mic.size(), mic.size());

  // The voice must still be there at close to its recorded level. Measured
  // after the settle window, over the whole rest of the clip.
  const size_t settle = static_cast<size_t>(kRate);
  const double before = Rms(mic, settle);
  const double after = Rms(result.mic, settle);
  EXPECT_GT(after, before * 0.7)
      << "the near-end voice was attenuated — this is the 'gutted voice' bug";
}

TEST(MicEchoCancellerTest, TheVoiceMaskFiresOnAnUncorrelatedMic) {
  // Directly: a mic dominated by something uncorrelated with the reference is
  // voice, whatever the levels involved.
  const int n = kRate;
  const auto reference = Noise(n, 17);
  const auto voice = Tone(n, 200.0, 0.2f);
  const auto env = MovingRms(voice);
  const auto mask = NearEndVoiceMask(voice, reference, env, kVoiceMicNoiseFloor);
  int flagged = 0;
  for (size_t i = 0; i < mask.size(); ++i) {
    if (mask[i]) ++flagged;
  }
  EXPECT_GT(flagged, n / 2) << "voice went undetected";
}

TEST(MicEchoCancellerTest, TheVoiceMaskStaysQuietOnPureBleed) {
  // The converse, and the reason detection uses the BLEED-aligned reference:
  // a pure-bleed window is a scaled copy of it and must NOT read as voice, or
  // the canceller would freeze exactly where it needs to work.
  const int n = kRate;
  const auto system = Noise(n, 19);
  const int delay = static_cast<int>(0.05 * kRate);
  const auto mic = MakeMic(system, delay, 0.3f, {});
  const auto reference = BleedAlignedReference(system, delay, mic.size());
  const auto env = MovingRms(mic);
  const auto mask = NearEndVoiceMask(mic, reference, env, kVoiceMicNoiseFloor);
  int flagged = 0;
  for (size_t i = static_cast<size_t>(delay); i < mask.size(); ++i) {
    if (mask[i]) ++flagged;
  }
  EXPECT_LT(flagged, static_cast<int>(mask.size()) / 10)
      << "pure bleed was mistaken for near-end voice";
}

// --- stability --------------------------------------------------------------

TEST(MicEchoCancellerTest, OutputStaysInScaleAfterASilentStretch) {
  // macOS algorithm version 5: adapting on a near-silent reference drove the
  // weights into a misadjusted state that then over-predicted in a later loud
  // pause, producing audible out-of-scale bursts. Half silence, then bleed.
  const int half = kRate * 2;
  std::vector<float> system(static_cast<size_t>(half), 0.0f);
  const auto loud = Noise(half, 23);
  system.insert(system.end(), loud.begin(), loud.end());
  const auto mic = MakeMic(system, static_cast<int>(0.05 * kRate), 0.3f, {});

  const auto result = CancelEcho(mic, system);
  ASSERT_EQ(result.mic.size(), mic.size());
  for (size_t i = 0; i < result.mic.size(); ++i) {
    EXPECT_TRUE(std::isfinite(result.mic[i])) << "non-finite at " << i;
    EXPECT_LT(std::abs(result.mic[i]), 2.0f)
        << "out-of-scale burst at " << i << " (adapted on silence)";
  }
}

TEST(MicEchoCancellerTest, NlmsHoldsTheFilterWhereFrozen) {
  // With adaptation frozen everywhere the filter never learns, so the error
  // signal is just the input. This is what protects the voice.
  const int n = 4000;
  const auto desired = Tone(n, 300.0, 0.4f);
  const auto reference = Noise(n, 29);
  const std::vector<bool> freeze(static_cast<size_t>(n), true);
  const auto out = NlmsDoubleTalk(desired, reference, freeze);
  ASSERT_EQ(out.size(), desired.size());
  for (size_t i = 0; i < out.size(); ++i) {
    EXPECT_FLOAT_EQ(out[i], desired[i]) << "the frozen filter adapted at " << i;
  }
}

// --- the smaller pieces -----------------------------------------------------

TEST(MicEchoCancellerTest, MovingRmsTracksLevelAndNeverGoesNaN) {
  const auto x = Tone(kRate, 100.0, 0.5f);
  const auto env = MovingRms(x);
  ASSERT_EQ(env.size(), x.size());
  for (const float v : env) {
    EXPECT_TRUE(std::isfinite(v));
    EXPECT_GE(v, 0.0f);
  }
  // A 0.5-amplitude sine has RMS 0.5/sqrt(2) ~= 0.354 once the window fills.
  EXPECT_NEAR(env.back(), 0.354, 0.03);
}

TEST(MicEchoCancellerTest, PercentileInterpolates) {
  const std::vector<float> v{0.0f, 1.0f, 2.0f, 3.0f, 4.0f};
  EXPECT_FLOAT_EQ(Percentile(v, 0.0), 0.0f);
  EXPECT_FLOAT_EQ(Percentile(v, 1.0), 4.0f);
  EXPECT_FLOAT_EQ(Percentile(v, 0.5), 2.0f);
  EXPECT_NEAR(Percentile(v, 0.95), 3.8f, 1e-5);
  EXPECT_FLOAT_EQ(Percentile({}, 0.5), 0.0f);
}

TEST(MicEchoCancellerTest, DecimateRemovesTheMean) {
  std::vector<float> x(800, 0.0f);
  for (size_t i = 0; i < x.size(); ++i) {
    x[i] = 5.0f + static_cast<float>(i % 8);  // large DC offset
  }
  const auto d = DecimateZeroMean(x, 8);
  ASSERT_EQ(d.size(), 100u);
  double mean = 0.0;
  for (const float v : d) mean += v;
  EXPECT_NEAR(mean / d.size(), 0.0, 1e-4)
      << "a DC offset would dominate every correlation";
}

TEST(MicEchoCancellerTest, AlignedReferencesZeroFillRatherThanWrap) {
  const std::vector<float> system{1.0f, 2.0f, 3.0f, 4.0f};
  // A wrap-around would splice unrelated audio into the reference and make the
  // filter chase a phantom.
  const auto bleed = BleedAlignedReference(system, 2, 4);
  ASSERT_EQ(bleed.size(), 4u);
  EXPECT_FLOAT_EQ(bleed[0], 0.0f);
  EXPECT_FLOAT_EQ(bleed[1], 0.0f);
  EXPECT_FLOAT_EQ(bleed[2], 1.0f);
  EXPECT_FLOAT_EQ(bleed[3], 2.0f);
}

TEST(MicEchoCancellerTest, DelayEstimateRejectsAnIndependentPair) {
  // The consensus requirement is what stops a coincidental correlation in one
  // window from engaging the canceller on bleed-free audio.
  const auto a = Noise(kRate * 2, 31);
  const auto b = Noise(kRate * 2, 37);
  const auto estimate = EstimateDelay(a, b);
  EXPECT_LT(std::abs(estimate.correlation), kGateCorrelation);
}

TEST(MicEchoCancellerTest, DelayEstimateFindsAKnownLag) {
  const int n = kRate * 3;
  const auto system = Noise(n, 41);
  const int delay = static_cast<int>(0.08 * kRate);
  const auto mic = MakeMic(system, delay, 0.4f, {});
  const auto estimate = EstimateDelay(mic, system);
  EXPECT_GE(std::abs(estimate.correlation), kGateCorrelation);
  EXPECT_NEAR(estimate.samples, delay, kDelaySearchDecimation * 4);
}

}  // namespace
}  // namespace clingfy::audio::echo
