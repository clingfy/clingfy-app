#include "Capture/Export/audio_sidecar_probe.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <vector>

#include "Encoding/audio_sidecar_writer.h"

namespace clingfy::capture::export_ {
namespace {

namespace fs = std::filesystem;

class AudioSidecarProbeTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = fs::temp_directory_path() / "clingfy-audio-probe-test";
    fs::create_directories(dir_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }

  fs::path dir_;
};

TEST_F(AudioSidecarProbeTest, EmptyPathFails) {
  EXPECT_FALSE(ProbeDecodableAudio(L""));
}

TEST_F(AudioSidecarProbeTest, MissingFileFails) {
  EXPECT_FALSE(ProbeDecodableAudio((dir_ / "not-there.m4a").wstring()));
}

TEST_F(AudioSidecarProbeTest, NonMediaFileFails) {
  // A crash-truncated or corrupt sidecar must degrade cleanly to the
  // embedded premix — the gate is exactly "decodes one sample".
  const fs::path junk = dir_ / "junk.m4a";
  {
    std::ofstream out(junk, std::ios::binary);
    out << "this is not an mpeg-4 container";
  }
  EXPECT_FALSE(ProbeDecodableAudio(junk.wstring()));
}

TEST_F(AudioSidecarProbeTest, RealSidecarPasses) {
  // Write a real AAC sidecar through the exact writer the recorder uses, so
  // this pins the full produce→probe contract end-to-end.
  const fs::path out = dir_ / "mic.mp4";
  clingfy::encoding::AudioSidecarWriter writer;
  if (auto err = writer.Open(out.string())) {
    GTEST_SKIP() << "AAC sink writer unavailable: " << err->message;
  }
  std::vector<std::int16_t> packet(480 * 2, 1200);  // 10 ms of low tone
  std::int64_t ts = 0;
  for (int i = 0; i < 10; ++i) {
    ASSERT_FALSE(writer.WriteSamples(packet.data(), 480, ts).has_value());
    ts += 100'000;
  }
  ASSERT_FALSE(writer.Finalize().has_value());

  EXPECT_TRUE(ProbeDecodableAudio(out.wstring()));
}

}  // namespace
}  // namespace clingfy::capture::export_
