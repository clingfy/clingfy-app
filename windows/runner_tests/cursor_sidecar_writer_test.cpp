#include "Capture/Cursor/cursor_sidecar_writer.h"

#include <gtest/gtest.h>

#include "Capture/Cursor/cursor_sidecar_reader.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace clingfy::capture {
namespace {

namespace fs = std::filesystem;

class CursorSidecarWriterTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = fs::temp_directory_path() / "clingfy-cursor-writer-test";
    fs::create_directories(dir_);
    path_ = (dir_ / "cursor.jsonl").string();
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }

  std::string ReadFile() {
    std::ifstream in(path_, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
  }

  fs::path dir_;
  std::string path_;
};

CursorSidecarWriter::Header MakeHeader() {
  CursorSidecarWriter::Header h;
  h.schema_version = 1;
  h.sample_rate_hz = 60;
  h.target_type = "display";
  h.width = 1920;
  h.height = 1080;
  h.origin_x = 0;
  h.origin_y = 0;
  return h;
}

// THE test this file was missing, and the reason the inline preview never
// zoomed on a single real recording: the preview shipped its own loader that
// hard-required a `ts_us` field, which this writer has never emitted. Nothing
// asserted that whatever reads the sidecar can read what the writer writes, so
// a parser that rejected 100% of real input stayed green indefinitely.
//
// Assert the round trip through the REAL bytes, not a hand-written fixture.
TEST_F(CursorSidecarWriterTest, WrittenBytesParseBackWithTheSharedReader) {
  CursorSidecarWriter writer;
  ASSERT_TRUE(writer.Open(path_, MakeHeader()));
  writer.WriteSample(16, 100, 50, 100, 50, true);
  writer.WriteSample(33, 200, 60, 200, 60, true);
  writer.WriteSample(50, 300, 70, 300, 70, false);
  writer.WriteClick(40, 200, 60, "left", true);
  writer.WriteClick(120, 200, 60, "left", false);
  writer.Close();

  const auto parsed = ParseCursorSidecar(ReadFile());
  ASSERT_TRUE(parsed.has_value()) << "the shared reader rejected the writer's "
                                     "own output";
  EXPECT_EQ(parsed->samples.size(), 3u);
  EXPECT_FALSE(parsed->clicks.empty())
      << "clicks were dropped — smart zoom keys off these";
  EXPECT_EQ(parsed->samples[0].t_ms, 16);
  EXPECT_EQ(parsed->samples[0].x, 100);
  EXPECT_EQ(parsed->samples[0].y, 50);
  EXPECT_TRUE(parsed->samples[0].visible);
  EXPECT_FALSE(parsed->samples[2].visible);
  EXPECT_EQ(parsed->width, 1920);
  EXPECT_EQ(parsed->target_type, "display");
}

TEST_F(CursorSidecarWriterTest, OpenWritesHeaderLine) {
  CursorSidecarWriter writer;
  ASSERT_TRUE(writer.Open(path_, MakeHeader()));
  EXPECT_TRUE(writer.is_open());
  writer.Close();

  const std::string contents = ReadFile();
  EXPECT_NE(contents.find("\"type\":\"header\""), std::string::npos);
  EXPECT_NE(contents.find("\"schemaVersion\":1"), std::string::npos);
  EXPECT_NE(contents.find("\"sampleRateHz\":60"), std::string::npos);
  EXPECT_NE(contents.find("\"targetType\":\"display\""), std::string::npos);
  EXPECT_NE(contents.find("\"width\":1920"), std::string::npos);
  // Exactly one line (the header), newline-terminated.
  EXPECT_EQ(std::count(contents.begin(), contents.end(), '\n'), 1);
}

TEST_F(CursorSidecarWriterTest, WritesSamplesAndClicksFlushed) {
  CursorSidecarWriter writer;
  ASSERT_TRUE(writer.Open(path_, MakeHeader()));
  writer.WriteSample(16, 100, 50, 100, 50, true);
  writer.WriteSample(33, 200, 60, 200, 60, true);
  writer.WriteClick(40, 200, 60, "left", true);
  writer.WriteClick(120, 200, 60, "left", false);
  // Read BEFORE Close to prove each write is flushed (crash-robustness).
  const std::string mid = ReadFile();
  EXPECT_NE(mid.find("\"type\":\"sample\",\"tMs\":16"), std::string::npos);
  EXPECT_NE(mid.find("\"x\":200,\"y\":60"), std::string::npos);
  EXPECT_NE(mid.find("\"type\":\"click\",\"tMs\":40"), std::string::npos);
  EXPECT_NE(mid.find("\"button\":\"left\",\"action\":\"down\""),
            std::string::npos);
  EXPECT_NE(mid.find("\"action\":\"up\""), std::string::npos);
  writer.Close();

  // header + 2 samples + 2 clicks = 5 lines.
  const std::string contents = ReadFile();
  EXPECT_EQ(std::count(contents.begin(), contents.end(), '\n'), 5);
}

TEST_F(CursorSidecarWriterTest, VisibleFalseSerializes) {
  CursorSidecarWriter writer;
  ASSERT_TRUE(writer.Open(path_, MakeHeader()));
  writer.WriteSample(10, -5, -5, -5, -5, false);
  writer.Close();
  EXPECT_NE(ReadFile().find("\"visible\":false"), std::string::npos);
}

TEST_F(CursorSidecarWriterTest, WritesAreNoOpWhenNotOpen) {
  CursorSidecarWriter writer;
  // No Open() — every write is a safe no-op, no crash.
  writer.WriteSample(0, 0, 0, 0, 0, true);
  writer.WriteClick(0, 0, 0, "left", true);
  writer.Flush();
  writer.Close();
  EXPECT_FALSE(writer.is_open());
}

TEST_F(CursorSidecarWriterTest, OpenFailsForUnwritablePath) {
  CursorSidecarWriter writer;
  // A path inside a directory that does not exist cannot be opened.
  const std::string bad =
      (dir_ / "no-such-subdir" / "cursor.jsonl").string();
  EXPECT_FALSE(writer.Open(bad, MakeHeader()));
  EXPECT_FALSE(writer.is_open());
}

}  // namespace
}  // namespace clingfy::capture
