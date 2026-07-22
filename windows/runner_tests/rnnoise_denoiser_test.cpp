#include "Audio/VoiceCleanup/rnnoise_denoiser.h"

#include <gtest/gtest.h>

#include <vector>

// Proves the vendored RNNoise C engine (macos/Runner/Capture/Audio/RNNoise,
// shared with macOS) actually builds, links, and runs on Windows -- the
// documented Phase-4 voice-cleanup blocker. These are behavior smokes on the
// wrapper, not a golden test of the model output.

namespace clingfy::audio::voice_cleanup {
namespace {

TEST(RnnoiseDenoiserTest, FrameSizeIs480) {
  // 10 ms at 48 kHz. Downstream mic-cache framing depends on this constant.
  EXPECT_EQ(RnnoiseDenoiser::FrameSize(), 480);
}

TEST(RnnoiseDenoiserTest, ConstructsWithBuiltInModel) {
  RnnoiseDenoiser denoiser;
  EXPECT_TRUE(denoiser.ok());
}

TEST(RnnoiseDenoiserTest, SuppressesWhiteNoiseAndReportsNoVoice) {
  RnnoiseDenoiser denoiser;
  ASSERT_TRUE(denoiser.ok());

  const int frame_size = RnnoiseDenoiser::FrameSize();
  std::vector<float> in(frame_size);
  std::vector<float> out(frame_size);

  // Deterministic LCG pseudo-noise at int16 range (the scale RNNoise expects).
  std::uint32_t seed = 12345u;
  double energy_in = 0.0;
  double energy_out = 0.0;
  float last_vad = 1.0f;

  for (int frame = 0; frame < 50; ++frame) {
    for (int i = 0; i < frame_size; ++i) {
      seed = seed * 1103515245u + 12345u;
      in[i] = static_cast<float>((seed >> 16) & 0x7fff) - 16384.0f;
    }
    last_vad = denoiser.ProcessFrame(in.data(), out.data());
    // Skip the first frames while the engine's internal buffers prime.
    if (frame >= 10) {
      for (int i = 0; i < frame_size; ++i) {
        energy_in += static_cast<double>(in[i]) * in[i];
        energy_out += static_cast<double>(out[i]) * out[i];
      }
    }
  }

  ASSERT_GT(energy_in, 0.0);
  // Pure noise: the denoiser should strip almost all of it (measured ratio is
  // ~0.0000). Assert a conservative >=3 dB drop so the test tracks "it really
  // denoises" without pinning the exact model output.
  EXPECT_LT(energy_out, energy_in * 0.5);
  // And it should not hallucinate voice in white noise.
  EXPECT_LT(last_vad, 0.5f);
}

}  // namespace
}  // namespace clingfy::audio::voice_cleanup
