#include "Capture/Export/export_audio.h"

#include <gtest/gtest.h>

#include <cmath>
#include <cstdint>
#include <vector>

namespace clingfy::capture::export_ {
namespace {

constexpr double kEps = 1e-4;

// ---- RequiresAudioProcessing: the fast-path gate predicate -------------------
//
// The single highest-risk Slice 4 trap is forcing every export to re-encode
// because the identity defaults (gain 0 / volume 100 / no normalize) wrongly
// read as "processing requested". These pin the gate stays off for defaults
// and on only for a real change. (The router's ReadDouble fallback value is
// pinned separately in router_stub_shapes_test.cpp.)

TEST(RequiresAudioProcessingTest, IdentityDefaultsNeedNoProcessing) {
  EXPECT_FALSE(RequiresAudioProcessing(0.0, 100.0, false));
}

TEST(RequiresAudioProcessingTest, PositiveGainNeedsProcessing) {
  EXPECT_TRUE(RequiresAudioProcessing(6.0, 100.0, false));
}

TEST(RequiresAudioProcessingTest, VolumeBelow100NeedsProcessing) {
  EXPECT_TRUE(RequiresAudioProcessing(0.0, 50.0, false));
}

TEST(RequiresAudioProcessingTest, NormalizeNeedsProcessing) {
  EXPECT_TRUE(RequiresAudioProcessing(0.0, 100.0, true));
}

TEST(RequiresAudioProcessingTest, NegativeGainStaysOnFastPath) {
  // Gain is amplify-only (clamped to 0), so a negative request is a no-op and
  // must NOT force a re-encode. Attenuation is volume's job.
  EXPECT_FALSE(RequiresAudioProcessing(-6.0, 100.0, false));
}

TEST(RequiresAudioProcessingTest, BenignRoundTripDoesNotTrip) {
  // A codec round-trip that nudges 100 -> 99.99999999 / 0 -> 0.0000001 must
  // stay on the fast-path (epsilon-guarded).
  EXPECT_FALSE(RequiresAudioProcessing(1e-9, 100.0 - 1e-9, false));
}

// ---- ResolveAudioGainStages: dB->linear, volume, normalize ------------------
//
// Gain and volume resolve to SEPARATE stages (macOS gain-tap then setVolume),
// not one collapsed multiplier; normalize folds the whole scale into the gain
// stage with volume = 1.0.

TEST(ResolveAudioGainStagesTest, DefaultsAreUnityStages) {
  const AudioGainStages s = ResolveAudioGainStages(0.0, 100.0, false, -16.0, 0.0);
  EXPECT_NEAR(s.gain, 1.0, kEps);
  EXPECT_NEAR(s.volume, 1.0, kEps);
}

TEST(ResolveAudioGainStagesTest, PositiveGainGoesInGainStage) {
  const AudioGainStages s = ResolveAudioGainStages(6.0, 100.0, false, -16.0, 0.0);
  EXPECT_NEAR(s.gain, std::pow(10.0, 6.0 / 20.0), kEps);  // ~1.99526
  EXPECT_NEAR(s.volume, 1.0, kEps);
}

TEST(ResolveAudioGainStagesTest, VolumeGoesInVolumeStage) {
  const AudioGainStages s = ResolveAudioGainStages(0.0, 50.0, false, -16.0, 0.0);
  EXPECT_NEAR(s.gain, 1.0, kEps);
  EXPECT_NEAR(s.volume, 0.5, kEps);
}

TEST(ResolveAudioGainStagesTest, GainAndVolumeStayInSeparateStages) {
  // The whole point of the two-stage form: they are NOT pre-multiplied.
  const AudioGainStages s = ResolveAudioGainStages(6.0, 50.0, false, -16.0, 0.0);
  EXPECT_NEAR(s.gain, std::pow(10.0, 6.0 / 20.0), kEps);
  EXPECT_NEAR(s.volume, 0.5, kEps);
}

TEST(ResolveAudioGainStagesTest, GainClampsAt24Db) {
  const AudioGainStages s = ResolveAudioGainStages(48.0, 100.0, false, -16.0, 0.0);
  EXPECT_NEAR(s.gain, std::pow(10.0, 24.0 / 20.0), kEps);
}

TEST(ResolveAudioGainStagesTest, NegativeGainClampsToUnityGain) {
  const AudioGainStages s = ResolveAudioGainStages(-6.0, 100.0, false, -16.0, 0.0);
  EXPECT_NEAR(s.gain, 1.0, kEps);  // gain clamps to a 0 dB floor
  EXPECT_NEAR(s.volume, 1.0, kEps);
}

TEST(ResolveAudioGainStagesTest, VolumeClampsAt100AndZero) {
  EXPECT_NEAR(ResolveAudioGainStages(0.0, 250.0, false, -16.0, 0.0).volume, 1.0,
              kEps);
  EXPECT_NEAR(ResolveAudioGainStages(0.0, 0.0, false, -16.0, 0.0).volume, 0.0,
              kEps);
}

TEST(ResolveAudioGainStagesTest, NormalizeFoldsScaleIntoGainStage) {
  // target -16 dBFS = 0.158489; source peak 0.5 -> scale 0.316979 in the gain
  // stage, volume left at unity.
  const double target_linear = std::pow(10.0, -16.0 / 20.0);
  const AudioGainStages s =
      ResolveAudioGainStages(0.0, 100.0, true, -16.0, /*peak=*/0.5);
  EXPECT_NEAR(s.gain, target_linear / 0.5, kEps);
  EXPECT_NEAR(s.volume, 1.0, kEps);
}

TEST(ResolveAudioGainStagesTest, NormalizeComposesWithUserGainAndVolume) {
  const double target_linear = std::pow(10.0, -16.0 / 20.0);
  const double user = 0.5 * std::pow(10.0, 6.0 / 20.0);  // vol 50% * +6 dB
  const AudioGainStages s =
      ResolveAudioGainStages(6.0, 50.0, true, -16.0, /*peak=*/0.5);
  EXPECT_NEAR(s.gain, user * (target_linear / 0.5), kEps);
  EXPECT_NEAR(s.volume, 1.0, kEps);
}

TEST(ResolveAudioGainStagesTest, NormalizeClampsNetToPlus24Db) {
  const AudioGainStages s =
      ResolveAudioGainStages(0.0, 100.0, true, -6.0, /*peak=*/0.0001);
  EXPECT_NEAR(s.gain, std::pow(10.0, 24.0 / 20.0), kEps);
}

TEST(ResolveAudioGainStagesTest, NormalizeSkippedOnSilentSourceFallsBack) {
  // peak <= 1e-6 -> plain user stages (here unity / unity).
  const AudioGainStages s =
      ResolveAudioGainStages(0.0, 100.0, true, -16.0, /*peak=*/0.0);
  EXPECT_NEAR(s.gain, 1.0, kEps);
  EXPECT_NEAR(s.volume, 1.0, kEps);
}

TEST(ResolveAudioGainStagesTest, NormalizeTargetClampsToRange) {
  // target -100 clamps to -24 dBFS; peak 1.0 -> gain = 10^(-24/20).
  const AudioGainStages s =
      ResolveAudioGainStages(0.0, 100.0, true, -100.0, /*peak=*/1.0);
  EXPECT_NEAR(s.gain, std::pow(10.0, -24.0 / 20.0), kEps);
}

// ---- ApplyAudioGain: two ordered stages, clamp + truncate per stage ---------

TEST(ApplyAudioGainTest, UnityIsNoOp) {
  std::vector<std::int16_t> s{1000, -1000, 500, -32768, 32767};
  const std::vector<std::int16_t> before = s;
  ApplyAudioGain(s.data(), s.size(), AudioGainStages{1.0, 1.0});
  EXPECT_EQ(s, before);
}

TEST(ApplyAudioGainTest, GainStageAmplifies) {
  std::vector<std::int16_t> s{1000, -1000};
  ApplyAudioGain(s.data(), s.size(), AudioGainStages{2.0, 1.0});
  EXPECT_EQ(s[0], 2000);
  EXPECT_EQ(s[1], -2000);
}

TEST(ApplyAudioGainTest, VolumeStageAttenuates) {
  std::vector<std::int16_t> s{100, -100};
  ApplyAudioGain(s.data(), s.size(), AudioGainStages{1.0, 0.5});
  EXPECT_EQ(s[0], 50);
  EXPECT_EQ(s[1], -50);
}

TEST(ApplyAudioGainTest, ClampsAtAsymmetricInt16Bounds) {
  std::vector<std::int16_t> s{20000, -20000};
  ApplyAudioGain(s.data(), s.size(), AudioGainStages{4.0, 1.0});  // 80000/-80000
  EXPECT_EQ(s[0], 32767);
  EXPECT_EQ(s[1], -32768);
}

TEST(ApplyAudioGainTest, TruncatesTowardZeroNotRounds) {
  // 3 * 0.5 = 1.5 -> 1 (truncate); -3 * 0.5 = -1.5 -> -1. Matches the macOS
  // `Int16(clipped)` cast; lround would give 2 / -2 and diverge.
  std::vector<std::int16_t> s{3, -3};
  ApplyAudioGain(s.data(), s.size(), AudioGainStages{1.0, 0.5});
  EXPECT_EQ(s[0], 1);
  EXPECT_EQ(s[1], -1);
}

TEST(ApplyAudioGainTest, GainClampsBeforeVolumeAttenuates) {
  // THE parity case: a loud source boosted (+12 dB, gain ~3.981) AND
  // attenuated (volume 25%). macOS clamps the gain stage to 32767 FIRST, then
  // *0.25 -> 8191. A single-multiply (sample * gain * volume) would instead
  // give clamp(30000 * 0.995) = 29858 — ~11 dB louder and differently
  // distorted. This pins the two-stage order.
  std::vector<std::int16_t> s{30000, -30000};
  ApplyAudioGain(s.data(), s.size(),
                 AudioGainStages{std::pow(10.0, 12.0 / 20.0), 0.25});
  EXPECT_EQ(s[0], 8191);   // trunc(32767 * 0.25)
  EXPECT_EQ(s[1], -8192);  // trunc(-32768 * 0.25)
}

TEST(ApplyAudioGainTest, TwoStagesMatchProductWhenNoClip) {
  // When the gain stage does not clip, the two-stage result equals the
  // single-multiply product (the common, non-edge case).
  std::vector<std::int16_t> s{1000, -2000};
  ApplyAudioGain(s.data(), s.size(), AudioGainStages{2.0, 0.5});  // net x1.0
  EXPECT_EQ(s[0], 1000);
  EXPECT_EQ(s[1], -2000);
}

// ---- Int16PeakLinear: whole-track peak for normalize ------------------------

TEST(Int16PeakLinearTest, EmptyBufferIsZero) {
  EXPECT_NEAR(Int16PeakLinear(nullptr, 0), 0.0, kEps);
}

TEST(Int16PeakLinearTest, FindsMaxAbsNormalizedBy32767) {
  std::vector<std::int16_t> s{1000, -16383, 200};
  EXPECT_NEAR(Int16PeakLinear(s.data(), s.size()), 16383.0 / 32767.0, kEps);
}

TEST(Int16PeakLinearTest, Int16MinMapsToOne) {
  std::vector<std::int16_t> s{-32768, 5};
  EXPECT_NEAR(Int16PeakLinear(s.data(), s.size()), 1.0, kEps);
}

TEST(Int16PeakLinearTest, FullScalePositiveIsOne) {
  std::vector<std::int16_t> s{32767};
  EXPECT_NEAR(Int16PeakLinear(s.data(), s.size()), 1.0, kEps);
}

}  // namespace
}  // namespace clingfy::capture::export_
