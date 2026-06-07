#include "Capture/Cursor/cursor_sampler.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>

namespace clingfy::capture {
namespace {

namespace fs = std::filesystem;

// A QPC frequency of 10,000,000 makes 1 tick == 1 hns (100 ns), so 10,000 ticks
// == 1 ms. The sampler's clock then reports ms = ticks / 10,000.
constexpr std::int64_t kTestQpcFreq = 10'000'000;
constexpr std::int64_t kTicksPerMs = 10'000;

class CursorSamplerTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = fs::temp_directory_path() / "clingfy-cursor-sampler-test";
    fs::create_directories(dir_);
    path_ = (dir_ / "cursor.jsonl").string();
    ticks_ = std::make_shared<std::int64_t>(0);
    probe_ = std::make_shared<CursorSampler::Probe>();
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }

  CursorSampler::Config Config() {
    CursorSampler::Config cfg;
    cfg.sidecar_path = path_;
    cfg.target_type = "display";
    cfg.width = 1920;
    cfg.height = 1080;
    cfg.header_origin_x = 0;
    cfg.header_origin_y = 0;
    cfg.sample_rate_hz = 60;
    cfg.heartbeat_ms = 1000;
    cfg.enable_click_hook = false;
    return cfg;
  }

  CursorSampler::ProbeFn Probe() {
    auto probe = probe_;
    return [probe]() { return *probe; };
  }
  CursorSampler::OriginFn ConstOrigin() {
    return [](std::int32_t& x, std::int32_t& y) { x = 0; y = 0; };
  }

  void Advance(std::int64_t ms) { *ticks_ += ms * kTicksPerMs; }

  std::string ReadFile() {
    std::ifstream in(path_, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
  }
  int LineCount() {
    const std::string c = ReadFile();
    return static_cast<int>(std::count(c.begin(), c.end(), '\n'));
  }

  fs::path dir_;
  std::string path_;
  std::shared_ptr<std::int64_t> ticks_;
  std::shared_ptr<CursorSampler::Probe> probe_;

  std::unique_ptr<CursorSampler> MakeSampler() {
    auto ticks = ticks_;
    return std::make_unique<CursorSampler>([ticks]() { return *ticks; },
                                           kTestQpcFreq);
  }
};

TEST_F(CursorSamplerTest, StartForTestingWritesHeaderAndOpensSidecar) {
  auto sampler = MakeSampler();
  ASSERT_TRUE(sampler->StartForTesting(Config(), Probe(), ConstOrigin()));
  EXPECT_TRUE(sampler->sidecar_open());
  sampler->Stop();
  EXPECT_NE(ReadFile().find("\"type\":\"header\""), std::string::npos);
}

TEST_F(CursorSamplerTest, StartForTestingFailsOnUnwritablePathFallback) {
  // The engine treats a false return as "keep the Phase 7 cursor-on fallback".
  auto sampler = MakeSampler();
  CursorSampler::Config bad = Config();
  bad.sidecar_path = (dir_ / "no-such-subdir" / "cursor.jsonl").string();
  EXPECT_FALSE(sampler->StartForTesting(bad, Probe(), ConstOrigin()));
  EXPECT_FALSE(sampler->sidecar_open());
}

TEST_F(CursorSamplerTest, EmitsMappedSamplesAndDedupsUnchanged) {
  auto sampler = MakeSampler();
  ASSERT_TRUE(sampler->StartForTesting(Config(), Probe(), ConstOrigin()));

  *probe_ = CursorSampler::Probe{100, 50, true};
  Advance(1);
  EXPECT_TRUE(sampler->RunOnceForTesting());  // first sample.

  // Unchanged position within the heartbeat → deduped (no new sample).
  Advance(5);
  EXPECT_FALSE(sampler->RunOnceForTesting());

  // Moved → emitted.
  *probe_ = CursorSampler::Probe{140, 50, true};
  Advance(5);
  EXPECT_TRUE(sampler->RunOnceForTesting());

  sampler->Stop();
  const std::string c = ReadFile();
  // header + 2 samples = 3 lines.
  EXPECT_EQ(std::count(c.begin(), c.end(), '\n'), 3);
  // Capture-local x == screen x here (origin 0,0); both 100 then 140.
  EXPECT_NE(c.find("\"x\":100,\"y\":50"), std::string::npos);
  EXPECT_NE(c.find("\"x\":140,\"y\":50"), std::string::npos);
}

TEST_F(CursorSamplerTest, TimestampsDoNotAdvanceWhilePaused) {
  auto sampler = MakeSampler();
  ASSERT_TRUE(sampler->StartForTesting(Config(), Probe(), ConstOrigin()));

  Advance(20);  // t = 20 ms
  const std::int64_t before_pause = sampler->NowMsForTesting();
  EXPECT_EQ(before_pause, 20);

  sampler->Pause();
  Advance(100);  // 100 ms of wall time elapses WHILE paused.
  sampler->Resume();
  // Recording time excludes the paused interval — back at ~20 ms, not 120 ms.
  EXPECT_EQ(sampler->NowMsForTesting(), 20);

  Advance(5);  // 5 ms after resume.
  EXPECT_EQ(sampler->NowMsForTesting(), 25);
  sampler->Stop();
}

TEST_F(CursorSamplerTest, RunOnceIsNoOpWhilePaused) {
  auto sampler = MakeSampler();
  ASSERT_TRUE(sampler->StartForTesting(Config(), Probe(), ConstOrigin()));
  *probe_ = CursorSampler::Probe{10, 10, true};
  Advance(1);
  ASSERT_TRUE(sampler->RunOnceForTesting());
  const int after_first = LineCount();

  sampler->Pause();
  *probe_ = CursorSampler::Probe{500, 500, true};  // would normally emit.
  Advance(1);
  EXPECT_FALSE(sampler->RunOnceForTesting());
  sampler->Stop();
  EXPECT_EQ(LineCount(), after_first)
      << "no samples should be written while paused";
}

}  // namespace
}  // namespace clingfy::capture
