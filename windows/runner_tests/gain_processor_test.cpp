#include "Audio/gain_processor.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cmath>
#include <thread>
#include <vector>

#include "Capture/Export/export_audio.h"

namespace clingfy::audio {
namespace {

constexpr double kRate = 48000.0;

// Runs enough frames for any ramp to complete, so a test that cares about the
// STEADY-STATE value is not reading a value mid-glide.
void Settle(GainProcessor* p) { p->Reset(); }

std::vector<float> Apply(GainProcessor* p, std::vector<float> samples,
                       std::uint32_t channels = 1) {
  p->Process(samples.data(), samples.size() / channels, channels);
  return samples;
}

// ---------------------------------------------------------------------------
// Parity with the export / edited-preview path.
// ---------------------------------------------------------------------------

// THE load-bearing test. `ApplyAudioGain` amplifies, HARD-LIMITS, and only then
// attenuates — so a clipping sample is limited before volume scales it.
// Collapsing the two stages into one `sample * gain * volume` multiply gives a
// louder answer for anything that clips, and the passthrough preview would stop
// matching both the export and the edited preview.
TEST(GainProcessorTest, ClampsBetweenTheGainAndVolumeStages) {
  GainProcessor p;
  p.Prepare(kRate);
  p.SetStages(GainStages{2.0, 0.5});
  Settle(&p);

  const auto out = Apply(&p, {0.6f});

  // gain: 0.6 * 2 = 1.2 -> clamped to 1.0. volume: 1.0 * 0.5 = 0.5.
  EXPECT_NEAR(out[0], 0.5f, 1e-6f);
  // The single-multiply answer would be 0.6 * 2 * 0.5 = 0.6. If this ever
  // passes, the intermediate clamp is gone.
  EXPECT_NE(std::lround(out[0] * 1000), std::lround(0.6f * 1000));
}

// Cross-check the float node against the int16 function the export and the
// edited preview actually run, on the same inputs. These must not drift.
TEST(GainProcessorTest, MatchesApplyAudioGainAcrossTheRange) {
  namespace exp = capture::export_;
  const exp::AudioGainStages stages{2.0, 0.5};

  for (const double sample : {0.0, 0.1, 0.25, 0.4, 0.6, 0.9, -0.3, -0.7, -0.95}) {
    GainProcessor p;
    p.Prepare(kRate);
    p.SetStages(GainStages{stages.gain, stages.volume});
    Settle(&p);
    const float got = Apply(&p, {static_cast<float>(sample)})[0];

    std::int16_t pcm = static_cast<std::int16_t>(std::lround(sample * 32767.0));
    exp::ApplyAudioGain(&pcm, 1, stages);
    const float expected = static_cast<float>(pcm) / 32767.0f;

    // int16 quantisation is the only permitted difference.
    EXPECT_NEAR(got, expected, 1.5e-4f) << "sample " << sample;
  }
}

// ---------------------------------------------------------------------------
// Behaviour
// ---------------------------------------------------------------------------

// Unity must be a bit-exact copy, not a multiply by 1.0 — an untouched preview
// should be unable to alter its own audio even in the last bit.
TEST(GainProcessorTest, UnityIsBitExactPassthrough) {
  GainProcessor p;
  p.Prepare(kRate);
  Settle(&p);

  const std::vector<float> in = {0.0f, 0.3f, -0.7f, 0.99f, -1.0f, 1.0f};
  const auto out = Apply(&p, in);
  for (size_t i = 0; i < in.size(); ++i) {
    EXPECT_EQ(out[i], in[i]) << "index " << i;
  }
}

TEST(GainProcessorTest, AmplifiesAndAttenuatesIndependently) {
  GainProcessor gain;
  gain.Prepare(kRate);
  gain.SetStages(GainStages{2.0, 1.0});
  Settle(&gain);
  EXPECT_NEAR(Apply(&gain, {0.25f})[0], 0.5f, 1e-6f);

  GainProcessor vol;
  vol.Prepare(kRate);
  vol.SetStages(GainStages{1.0, 0.25});
  Settle(&vol);
  EXPECT_NEAR(Apply(&vol, {0.8f})[0], 0.2f, 1e-6f);
}

// Channels are interleaved; every channel of a frame gets the same scale.
// Applying the ramp per SAMPLE instead of per FRAME would skew a stereo image
// during a slider move.
TEST(GainProcessorTest, ScalesEveryChannelOfAFrameIdentically) {
  GainProcessor p;
  p.Prepare(kRate);
  p.SetStages(GainStages{1.0, 0.5});
  Settle(&p);

  const auto out = Apply(&p, {0.4f, 0.4f, 0.8f, 0.8f}, 2);
  EXPECT_NEAR(out[0], out[1], 1e-7f);
  EXPECT_NEAR(out[2], out[3], 1e-7f);
  EXPECT_NEAR(out[0], 0.2f, 1e-6f);
}

// A step change must GLIDE. Jumping the multiplier between two buffers is a
// discontinuity in the waveform, which is a click — the reason a raw
// MediaPlayer.Volume write is not good enough on its own.
TEST(GainProcessorTest, RampsInsteadOfJumping) {
  GainProcessor p;
  p.Prepare(kRate);
  Settle(&p);  // starts at unity
  p.SetStages(GainStages{1.0, 0.0});  // hard mute request

  // One millisecond at 48 kHz is well inside the 10 ms ramp.
  std::vector<float> block(48, 1.0f);
  p.Process(block.data(), block.size(), 1);

  EXPECT_LT(block.front(), 1.0f) << "no ramp applied at all";
  EXPECT_GT(block.back(), 0.0f) << "reached the target instantly — that clicks";
  // Monotonic descent, no overshoot.
  for (size_t i = 1; i < block.size(); ++i) {
    EXPECT_LE(block[i], block[i - 1] + 1e-6f) << "index " << i;
    EXPECT_GE(block[i], 0.0f);
  }
}

// The glide must finish, and finish exactly on the target rather than
// oscillating around it.
TEST(GainProcessorTest, RampSettlesExactlyOnTheTarget) {
  GainProcessor p;
  p.Prepare(kRate);
  Settle(&p);
  p.SetStages(GainStages{1.0, 0.25});

  // Well past the 10 ms ramp.
  std::vector<float> block(4800, 1.0f);
  p.Process(block.data(), block.size(), 1);

  EXPECT_NEAR(p.SmoothedStages().volume, 0.25, 1e-9);
  EXPECT_NEAR(block.back(), 0.25f, 1e-6f);
}

// Ramp length is wall-clock, not buffer-relative: a host that hands over tiny
// buffers must not make the glide 100x slower.
TEST(GainProcessorTest, RampLengthIsIndependentOfBufferSize) {
  auto run_to_target = [](std::size_t block_size) {
    GainProcessor p;
    p.Prepare(kRate);
    p.Reset();
    p.SetStages(GainStages{1.0, 0.0});
    std::size_t frames = 0;
    for (int i = 0; i < 1000 && p.SmoothedStages().volume > 1e-4; ++i) {
      std::vector<float> block(block_size, 1.0f);
      p.Process(block.data(), block.size(), 1);
      frames += block_size;
    }
    return frames;
  };
  const std::size_t small = run_to_target(16);
  const std::size_t large = run_to_target(512);
  // Both should land near the 480-frame (10 ms) ramp, within one block.
  EXPECT_NEAR(static_cast<double>(small), 480.0, 32.0);
  EXPECT_NEAR(static_cast<double>(large), 480.0, 600.0);
}

// Reset exists for seeks and device rebuilds, where there is no previous audio
// to glide from and a ramp would be an audible fade-in on the first buffer.
TEST(GainProcessorTest, ResetJumpsStraightToTheTarget) {
  GainProcessor p;
  p.Prepare(kRate);
  p.SetStages(GainStages{1.0, 0.5});
  p.Reset();

  EXPECT_NEAR(p.SmoothedStages().volume, 0.5, 1e-9);
  EXPECT_NEAR(Apply(&p, {1.0f})[0], 0.5f, 1e-6f);
}

// ---------------------------------------------------------------------------
// Robustness
// ---------------------------------------------------------------------------

TEST(GainProcessorTest, ToleratesDegenerateBuffersAndRates) {
  GainProcessor p;
  p.Prepare(0.0);  // must not divide by zero or produce an infinite ramp
  p.SetStages(GainStages{2.0, 1.0});
  Settle(&p);

  std::vector<float> block = {0.25f};
  p.Process(nullptr, 4, 1);              // null buffer
  p.Process(block.data(), 0, 1);         // no frames
  p.Process(block.data(), 1, 0);         // no channels
  EXPECT_EQ(block[0], 0.25f) << "a degenerate call modified the buffer";

  p.Process(block.data(), 1, 1);
  EXPECT_NEAR(block[0], 0.5f, 1e-6f);
}

// A negative multiplier inverts phase rather than changing level — nothing in
// the UI can mean that, so it is clamped away at the boundary.
TEST(GainProcessorTest, RefusesNegativeAndOutOfRangeStages) {
  GainProcessor p;
  p.SetStages(GainStages{-3.0, -1.0});
  EXPECT_GE(p.TargetStages().gain, 0.0);
  EXPECT_GE(p.TargetStages().volume, 0.0);

  p.SetStages(GainStages{1.0, 5.0});
  EXPECT_LE(p.TargetStages().volume, 1.0) << "volume only attenuates";
}

// Both stages ride in one atomic word, so a reader can never pair a new gain
// with an old volume. Two separate atomics would tear across the pair and the
// mismatched frame is a click at exactly the moment a slider moves.
TEST(GainProcessorTest, PublishesBothStagesAtomically) {
  GainProcessor p;
  p.Prepare(kRate);

  // Prime with one of the two pairs: the reader starts immediately and would
  // otherwise count the initial unity value as a tear.
  p.SetStages(GainStages{4.0, 0.25});

  std::atomic<bool> stop{false};
  std::atomic<int> mismatches{0};

  // Writer alternates between two pairs that share no component value.
  std::thread writer([&] {
    bool a = true;
    while (!stop.load(std::memory_order_relaxed)) {
      p.SetStages(a ? GainStages{4.0, 0.25} : GainStages{2.0, 0.75});
      a = !a;
    }
  });

  for (int i = 0; i < 200000; ++i) {
    const GainStages s = p.TargetStages();
    const bool valid = (std::abs(s.gain - 4.0) < 1e-6 &&
                        std::abs(s.volume - 0.25) < 1e-6) ||
                       (std::abs(s.gain - 2.0) < 1e-6 &&
                        std::abs(s.volume - 0.75) < 1e-6);
    if (!valid) mismatches.fetch_add(1, std::memory_order_relaxed);
  }
  stop.store(true, std::memory_order_relaxed);
  writer.join();

  EXPECT_EQ(mismatches.load(), 0) << "the stage pair tore";
}

// Process() runs under a real-time deadline. It must not be the thing that
// allocates. Exercised indirectly: a long run with changing targets must not
// grow, and this at least pins that Process is callable in a tight loop with
// no setup between calls.
TEST(GainProcessorTest, ProcessIsCallableInATightRealTimeLoop) {
  GainProcessor p;
  p.Prepare(kRate);
  p.Reset();

  std::vector<float> block(480, 0.5f);
  for (int i = 0; i < 2000; ++i) {
    p.SetStages(GainStages{1.0 + (i % 4) * 0.5, 1.0 - (i % 3) * 0.25});
    p.Process(block.data(), block.size(), 1);
    std::fill(block.begin(), block.end(), 0.5f);
  }
  SUCCEED();
}

}  // namespace
}  // namespace clingfy::audio
