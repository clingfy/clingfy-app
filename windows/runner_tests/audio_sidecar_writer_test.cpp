#include "Encoding/audio_sidecar_writer.h"

#include <gtest/gtest.h>

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace clingfy::encoding {
namespace {

namespace fs = std::filesystem;

class AudioSidecarWriterTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = fs::temp_directory_path() / "clingfy-audio-sidecar-test";
    fs::create_directories(dir_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }

  fs::path dir_;
};

TEST_F(AudioSidecarWriterTest, OpenOnAnUnwritablePathFailsSoftly) {
  AudioSidecarWriter writer;
  const auto err = writer.Open(
      (dir_ / "no-such-subdir" / "deeper" / "mic.mp4").string());
  // The sidecar contract is best-effort: a bad path must produce an
  // EncoderError (which the engine downgrades to "no sidecar"), never a
  // crash or a hang.
  ASSERT_TRUE(err.has_value());
  EXPECT_FALSE(err->message.empty());
  EXPECT_EQ(writer.samples_written(), 0u);
}

TEST_F(AudioSidecarWriterTest, EmptyPathIsRejected) {
  AudioSidecarWriter writer;
  const auto err = writer.Open("");
  ASSERT_TRUE(err.has_value());
}

TEST_F(AudioSidecarWriterTest, WriteBeforeOpenFailsSoftly) {
  AudioSidecarWriter writer;
  const std::int16_t samples[4] = {0, 0, 0, 0};
  const auto err = writer.WriteSamples(samples, /*frame_count=*/2,
                                       /*timestamp_hns=*/0);
  ASSERT_TRUE(err.has_value());
}

TEST_F(AudioSidecarWriterTest, RoundTripProducesANonEmptyFinalizedFile) {
  AudioSidecarWriter writer;
  const fs::path out = dir_ / "mic.mp4";
  if (auto err = writer.Open(out.string())) {
    // CI images without the AAC encoder MFT can't run the encode leg; the
    // path/state tests above still cover the writer's contract.
    GTEST_SKIP() << "AAC sink writer unavailable: " << err->message;
  }

  // 100 ms of a 440 Hz sine at 48 kHz stereo, written in 10 ms packets on
  // the mixer's synthetic timeline (10 ms = 100'000 hns).
  constexpr std::uint32_t kFramesPerPacket = 480;
  std::vector<std::int16_t> packet(kFramesPerPacket * 2);
  std::int64_t timestamp_hns = 0;
  for (int p = 0; p < 10; ++p) {
    for (std::uint32_t f = 0; f < kFramesPerPacket; ++f) {
      const double t =
          (p * static_cast<double>(kFramesPerPacket) + f) / 48000.0;
      const auto v = static_cast<std::int16_t>(
          20000.0 * std::sin(2.0 * 3.14159265358979 * 440.0 * t));
      packet[f * 2] = v;
      packet[f * 2 + 1] = v;
    }
    ASSERT_FALSE(
        writer.WriteSamples(packet.data(), kFramesPerPacket, timestamp_hns)
            .has_value());
    timestamp_hns += 100'000;
  }
  EXPECT_EQ(writer.samples_written(), 10u * kFramesPerPacket);

  ASSERT_FALSE(writer.Finalize().has_value());

  std::error_code ec;
  ASSERT_TRUE(fs::exists(out, ec));
  // A finalized 100 ms AAC file carries real bitstream + moov — anything
  // over a KiB proves the encode leg ran; an empty/near-empty file means
  // the footer was never written.
  EXPECT_GT(fs::file_size(out, ec), 1024u);
}

TEST_F(AudioSidecarWriterTest, CancelAbandonsWithoutFinalize) {
  AudioSidecarWriter writer;
  const fs::path out = dir_ / "cancelled.mp4";
  if (auto err = writer.Open(out.string())) {
    GTEST_SKIP() << "AAC sink writer unavailable: " << err->message;
  }
  const std::int16_t samples[4] = {100, 100, 100, 100};
  ASSERT_FALSE(
      writer.WriteSamples(samples, /*frame_count=*/2, /*timestamp_hns=*/0)
          .has_value());
  writer.Cancel();
  // Cancel is idempotent and a post-cancel Finalize is a no-op success.
  writer.Cancel();
  EXPECT_FALSE(writer.Finalize().has_value());
}

}  // namespace
}  // namespace clingfy::encoding
