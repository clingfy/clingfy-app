#include "Capture/Export/mic_cleanup.h"

#include <gtest/gtest.h>

#include <mfidl.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "Capture/Export/audio_sidecar_probe.h"
#include "Encoding/audio_sidecar_writer.h"

// End-to-end smoke for the export voice-cleanup pre-pass: generate a noisy mic
// sidecar with the real AudioSidecarWriter, run it through ProduceCleanedMic
// (which drives the RNNoise engine), and decode the result back to confirm the
// noise was actually stripped. Not a golden test of the model output.

namespace clingfy::capture::export_ {
namespace {

namespace fs = std::filesystem;
using Microsoft::WRL::ComPtr;

// Write `seconds` of int16 white noise to a stereo AAC .mp4 at `path`.
bool WriteNoisyMic(const std::string& path, int seconds) {
  clingfy::encoding::AudioSidecarWriter writer;
  if (writer.Open(path).has_value()) {
    return false;
  }
  constexpr int kRate = 48'000;
  constexpr int kChunk = 4'800;  // 100 ms of frames per write
  std::uint32_t seed = 22'222u;
  std::vector<std::int16_t> stereo(static_cast<std::size_t>(kChunk) * 2);
  std::int64_t frames = 0;
  for (int c = 0; c < seconds * 10; ++c) {
    for (int i = 0; i < kChunk; ++i) {
      seed = seed * 1103515245u + 12345u;
      const auto s = static_cast<std::int16_t>(
          (static_cast<int>((seed >> 16) & 0x7fff)) - 16384);
      stereo[static_cast<std::size_t>(i) * 2] = s;
      stereo[static_cast<std::size_t>(i) * 2 + 1] = s;
    }
    const std::int64_t ts = frames * 10'000'000 / kRate;
    if (writer.WriteSamples(stereo.data(), kChunk, ts).has_value()) {
      return false;
    }
    frames += kChunk;
  }
  return !writer.Finalize().has_value();
}

// Decode `path` to mono 48 kHz int16 and return the summed sample energy.
// Returns -1 on any decode failure.
double DecodeMonoEnergy(const std::wstring& path) {
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return -1.0;
  }
  const DWORD kStream =
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(kStream, TRUE);
  ComPtr<IMFMediaType> pcm;
  if (FAILED(::MFCreateMediaType(pcm.GetAddressOf()))) {
    return -1.0;
  }
  pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  pcm->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
  if (FAILED(reader->SetCurrentMediaType(kStream, nullptr, pcm.Get()))) {
    return -1.0;
  }
  double energy = 0.0;
  for (;;) {
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(kStream, 0, nullptr, &flags, &ts,
                                  sample.GetAddressOf()))) {
      return -1.0;
    }
    if (sample != nullptr) {
      ComPtr<IMFMediaBuffer> buffer;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) &&
          buffer != nullptr) {
        BYTE* data = nullptr;
        DWORD cur = 0;
        if (SUCCEEDED(buffer->Lock(&data, nullptr, &cur)) && data != nullptr) {
          const auto* s16 = reinterpret_cast<const std::int16_t*>(data);
          const std::size_t n = cur / sizeof(std::int16_t);
          for (std::size_t i = 0; i < n; ++i) {
            energy += static_cast<double>(s16[i]) * s16[i];
          }
          buffer->Unlock();
        }
      }
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
  }
  return energy;
}

class MicCleanupTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = fs::temp_directory_path() / "clingfy-mic-cleanup-test";
    fs::create_directories(dir_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }
  fs::path dir_;
};

TEST(VoiceCleanupWetMixTest, LightIsGentlerThanBalanced) {
  EXPECT_FLOAT_EQ(VoiceCleanupWetMix("light"), 0.5f);
  EXPECT_FLOAT_EQ(VoiceCleanupWetMix("balanced"), 1.0f);
  // Unknown / reserved / empty fall back to full strength.
  EXPECT_FLOAT_EQ(VoiceCleanupWetMix("highQuality"), 1.0f);
  EXPECT_FLOAT_EQ(VoiceCleanupWetMix(""), 1.0f);
}

TEST_F(MicCleanupTest, EmptyPathsFailSoftly) {
  EXPECT_FALSE(ProduceCleanedMic(L"", "out.mp4", nullptr, 1.0f));
  EXPECT_FALSE(ProduceCleanedMic(L"in.mp4", "", nullptr, 1.0f));
}

TEST_F(MicCleanupTest, UnreadableSourceFailsSoftly) {
  const auto out = (dir_ / "cleaned.mp4").string();
  EXPECT_FALSE(ProduceCleanedMic((dir_ / "does-not-exist.mp4").wstring(), out,
                                 nullptr, 1.0f));
}

TEST_F(MicCleanupTest, DenoisesAndProducesADecodableFile) {
  const auto noisy = (dir_ / "mic.mp4").string();
  ASSERT_TRUE(WriteNoisyMic(noisy, /*seconds=*/2));

  const auto cleaned = (dir_ / "mic-cleaned.mp4").string();
  ASSERT_TRUE(ProduceCleanedMic(fs::path(noisy).wstring(), cleaned, nullptr,
                                /*wet_mix=*/1.0f));

  // The output must be a valid, pump-openable sidecar.
  EXPECT_TRUE(ProbeDecodableAudio(fs::path(cleaned).wstring()));

  // And the white noise must be largely gone.
  const double noisy_energy = DecodeMonoEnergy(fs::path(noisy).wstring());
  const double clean_energy = DecodeMonoEnergy(fs::path(cleaned).wstring());
  ASSERT_GT(noisy_energy, 0.0);
  ASSERT_GE(clean_energy, 0.0);
  EXPECT_LT(clean_energy, noisy_energy * 0.5);
}

TEST_F(MicCleanupTest, LightRetainsMoreNoiseThanBalanced) {
  const auto noisy = (dir_ / "mic.mp4").string();
  ASSERT_TRUE(WriteNoisyMic(noisy, /*seconds=*/2));

  const auto light = (dir_ / "mic-light.mp4").string();
  const auto balanced = (dir_ / "mic-balanced.mp4").string();
  ASSERT_TRUE(ProduceCleanedMic(fs::path(noisy).wstring(), light, nullptr,
                                VoiceCleanupWetMix("light")));
  ASSERT_TRUE(ProduceCleanedMic(fs::path(noisy).wstring(), balanced, nullptr,
                                VoiceCleanupWetMix("balanced")));

  const double noisy_energy = DecodeMonoEnergy(fs::path(noisy).wstring());
  const double light_energy = DecodeMonoEnergy(fs::path(light).wstring());
  const double balanced_energy = DecodeMonoEnergy(fs::path(balanced).wstring());
  ASSERT_GT(noisy_energy, 0.0);
  // Both suppress the noise, but light (a 50% wet/dry blend) leaves audibly
  // more of the original than balanced (full RNNoise): balanced < light < noisy.
  EXPECT_LT(balanced_energy, light_energy);
  EXPECT_LT(light_energy, noisy_energy);
}

TEST_F(MicCleanupTest, CancelStopsAndReportsFailure) {
  const auto noisy = (dir_ / "mic.mp4").string();
  ASSERT_TRUE(WriteNoisyMic(noisy, /*seconds=*/2));
  const auto cleaned = (dir_ / "mic-cancel.mp4").string();
  EXPECT_FALSE(ProduceCleanedMic(fs::path(noisy).wstring(), cleaned,
                                 [] { return true; }, 1.0f));
}

}  // namespace
}  // namespace clingfy::capture::export_
