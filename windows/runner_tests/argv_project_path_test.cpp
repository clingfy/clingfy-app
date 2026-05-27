#include "Core/argv_project_path.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace clingfy::core {
namespace {

TEST(ArgvProjectPathTest, EmptyArgvReturnsNullopt) {
  EXPECT_FALSE(ExtractClingfyProjPath({}).has_value());
}

TEST(ArgvProjectPathTest, ArgvWithoutClingfyProjReturnsNullopt) {
  EXPECT_FALSE(
      ExtractClingfyProjPath({L"C:\\app.exe", L"--observatory-port=12345"})
          .has_value());
}

TEST(ArgvProjectPathTest, ExtractsClingfyProjPathFromArgv) {
  // Explorer's typical argv shape: [exe, project path]. The function
  // tolerates argv[0] because the helper accepts a full argv vector.
  const auto result = ExtractClingfyProjPath(
      {L"C:\\app.exe", L"C:\\Users\\me\\Recording.clingfyproj"});
  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(*result, L"C:\\Users\\me\\Recording.clingfyproj");
}

TEST(ArgvProjectPathTest, ExtensionCaseInsensitive) {
  const auto result =
      ExtractClingfyProjPath({L"foo", L"D:\\Stuff\\Sample.CLINGFYPROJ"});
  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(*result, L"D:\\Stuff\\Sample.CLINGFYPROJ");
}

TEST(ArgvProjectPathTest, FlagsSkippedEvenIfEndingInExtension) {
  // Pathologic: a flag literal that happens to end in .clingfyproj.
  // We should still pick the real path that follows it.
  const auto result = ExtractClingfyProjPath(
      {L"app", L"--foo=bar.clingfyproj",
       L"C:\\real\\path.clingfyproj"});
  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(*result, L"C:\\real\\path.clingfyproj");
}

TEST(ArgvProjectPathTest, ReturnsFirstMatchIfMultiple) {
  // Tooling never sends two .clingfyproj args, but if it did we keep
  // the first match -- matches user mental model of "open this one".
  const auto result =
      ExtractClingfyProjPath({L"app", L"C:\\a.clingfyproj",
                              L"C:\\b.clingfyproj"});
  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(*result, L"C:\\a.clingfyproj");
}

TEST(ArgvProjectPathTest, FromCommandLineHandlesQuotedPaths) {
  // CommandLineToArgvW must respect the quoting that Explorer applies
  // when a path contains spaces. The receiver of WM_COPYDATA / argv
  // both rely on this; rolling our own split would mangle this case.
  const auto result = ExtractClingfyProjPathFromCommandLine(
      LR"("C:\Users\me with spaces\Recording.clingfyproj")");
  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(*result, L"C:\\Users\\me with spaces\\Recording.clingfyproj");
}

TEST(ArgvProjectPathTest, FromCommandLineNullSafe) {
  EXPECT_FALSE(
      ExtractClingfyProjPathFromCommandLine(nullptr).has_value());
  EXPECT_FALSE(ExtractClingfyProjPathFromCommandLine(L"").has_value());
}

TEST(ArgvProjectPathTest, WideToUtf8RoundTrip) {
  EXPECT_EQ(WideToUtf8(L"C:\\Users\\me\\Recording.clingfyproj"),
            "C:\\Users\\me\\Recording.clingfyproj");
  EXPECT_EQ(WideToUtf8(L""), std::string{});
  // Build a wide string from raw codepoints (no source-file encoding
  // ambiguity). U+00DC (Ü) -> 0xC3 0x9C; U+4E2D (中) -> 0xE4 0xB8 0xAD.
  std::wstring w;
  w.push_back(L'C');
  w.push_back(L':');
  w.push_back(L'\\');
  w.push_back(static_cast<wchar_t>(0x00DC));
  w.push_back(L'-');
  w.push_back(static_cast<wchar_t>(0x4E2D));
  w.push_back(L'\\');
  w.push_back(L'a');
  const std::string u8 = WideToUtf8(w);
  EXPECT_NE(u8.find("\xC3\x9C"), std::string::npos)
      << "U+00DC should round-trip as 0xC3 0x9C";
  EXPECT_NE(u8.find("\xE4\xB8\xAD"), std::string::npos)
      << "U+4E2D should round-trip as 0xE4 0xB8 0xAD";
}

}  // namespace
}  // namespace clingfy::core
