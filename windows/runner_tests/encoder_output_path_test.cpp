#include "Encoding/encoder_output_path.h"

#include <gtest/gtest.h>

namespace clingfy::encoding {
namespace {

TEST(EncoderOutputPathTest, SanitizePassesSafeChars) {
  EXPECT_EQ(SanitizeSessionId("abc-123_DEF.bin"), "abc-123_DEF.bin");
}

TEST(EncoderOutputPathTest, SanitizeReplacesUnsafeChars) {
  EXPECT_EQ(SanitizeSessionId("a b/c\\d:e*f?g\"h<i>j|k"),
            "a_b_c_d_e_f_g_h_i_j_k");
}

TEST(EncoderOutputPathTest, SanitizeFallsBackForEmptyInput) {
  EXPECT_EQ(SanitizeSessionId(""), "session");
  // An input made entirely of unsafe chars still sanitizes to safe ones
  // (underscores), so the fallback only triggers on truly empty input.
  EXPECT_EQ(SanitizeSessionId("///"), "___");
}

TEST(EncoderOutputPathTest, ResolveJoinsTempAndSession) {
  const auto path = ResolveTempMp4Path("session-42", "C:\\Temp");
  EXPECT_EQ(path, "C:\\Temp\\clingfy_session-42.mp4");
}

TEST(EncoderOutputPathTest, ResolveTrimsTrailingSlashOnTempDir) {
  EXPECT_EQ(ResolveTempMp4Path("s1", "C:\\Temp\\"),
            "C:\\Temp\\clingfy_s1.mp4");
  EXPECT_EQ(ResolveTempMp4Path("s1", "C:/Temp/"),
            "C:/Temp\\clingfy_s1.mp4");
}

TEST(EncoderOutputPathTest, ResolveUsesEnvWhenNoOverride) {
  const auto path = ResolveTempMp4Path("env-test");
  EXPECT_NE(path.find("clingfy_env-test.mp4"), std::string::npos);
  // The path must be absolute — either drive-letter prefixed or
  // UNC-style. Anything else means we fell back to a relative path
  // which `MFCreateSinkWriterFromURL` rejects.
  EXPECT_TRUE(path.size() > 3 &&
              (path[1] == ':' || (path[0] == '\\' && path[1] == '\\')))
      << "ResolveTempMp4Path must produce an absolute path; got: " << path;
}

TEST(EncoderOutputPathTest, ResolveSanitizesUnsafeSessionId) {
  // `.` is in the safe-char set (filenames need dots), so the `/`s
  // sanitize to `_` but the `..` survives in-place. The trailing
  // `.mp4` is appended after sanitization, so a `..` inside the
  // filename can't escape the temp dir.
  EXPECT_EQ(ResolveTempMp4Path("dir/../escape", "C:\\Temp"),
            "C:\\Temp\\clingfy_dir_.._escape.mp4");
}

}  // namespace
}  // namespace clingfy::encoding
