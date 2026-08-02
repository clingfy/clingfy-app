#include "Services/log_locations.h"

#include "Core/app_identity.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <string>

namespace clingfy::storage {
namespace {

// Phase 10.1: native logs moved off the CWD-relative build\windows-poc to
// %LOCALAPPDATA%\Clingfy\Logs. These pin the path joiners, the FileLogSink
// file-name contract, and the env override used by tests and support.

TEST(LogLocationsTest, JoinNativeLogsDirAppendsClingfyLogs) {
  EXPECT_EQ(JoinNativeLogsDir(L"C:\\Users\\u\\AppData\\Local"),
            L"C:\\Users\\u\\AppData\\Local\\Clingfy\\Logs");
}

// D9: the native log directory must follow the CHANNEL identity, not a
// hardcoded literal. It was missed when the rest of D9 landed — dev and prod
// kept sharing one log directory after their recordings, caches and Dart logs
// had already separated — so this asserts agreement with the identity helper
// rather than re-stating the string, which is what let the miss survive.
TEST(LogLocationsTest, JoinNativeLogsDirFollowsTheChannelIdentity) {
  const std::wstring base = L"C:\\Users\\u\\AppData\\Local";
  const std::wstring expected =
      base + L"\\" + clingfy::core::LocalAppDataFolderName() + L"\\Logs";
  EXPECT_EQ(JoinNativeLogsDir(base), expected);
}

// And the two channels must not collide, or the split is cosmetic.
TEST(LogLocationsTest, DevAndProdNativeLogDirsDiffer) {
  EXPECT_NE(clingfy::core::LocalAppDataFolderName(clingfy::core::AppChannel::kDev),
            clingfy::core::LocalAppDataFolderName(clingfy::core::AppChannel::kProd));
}

TEST(LogLocationsTest, JoinNativeLogsDirEmptyBaseYieldsEmpty) {
  EXPECT_TRUE(JoinNativeLogsDir(L"").empty());
}

TEST(LogLocationsTest, JoinDartLogsDirUsesCompanyAndProduct) {
  EXPECT_EQ(JoinDartLogsDir(L"C:\\Users\\u\\AppData\\Roaming",
                            L"com.clingfy", L"clingfy"),
            L"C:\\Users\\u\\AppData\\Roaming\\com.clingfy\\clingfy\\Logs");
}

TEST(LogLocationsTest, JoinDartLogsDirEmptyPartsYieldEmpty) {
  EXPECT_TRUE(JoinDartLogsDir(L"", L"com.clingfy", L"clingfy").empty());
  EXPECT_TRUE(JoinDartLogsDir(L"C:\\x", L"", L"clingfy").empty());
  EXPECT_TRUE(JoinDartLogsDir(L"C:\\x", L"com.clingfy", L"").empty());
}

TEST(LogLocationsTest, DartLogFileNameMatchesFileLogSinkContract) {
  // FileLogSink writes logs_YYYY-MM-DD.jsonl with zero-padded fields.
  EXPECT_EQ(DartLogFileNameForDate(2026, 6, 9), L"logs_2026-06-09.jsonl");
  EXPECT_EQ(DartLogFileNameForDate(2026, 12, 31), L"logs_2026-12-31.jsonl");
}

TEST(LogLocationsTest, NativeLogsDirectoryHonorsEnvOverride) {
  ::SetEnvironmentVariableW(L"CLINGFY_NATIVE_LOG_DIR", L"C:\\override\\logs");
  EXPECT_EQ(NativeLogsDirectory(), L"C:\\override\\logs");
  ::SetEnvironmentVariableW(L"CLINGFY_NATIVE_LOG_DIR", nullptr);
}

TEST(LogLocationsTest, NativeLogsDirectoryResolvesUnderLocalAppData) {
  ::SetEnvironmentVariableW(L"CLINGFY_NATIVE_LOG_DIR", nullptr);
  const std::wstring dir = NativeLogsDirectory();
  ASSERT_FALSE(dir.empty());
  const std::wstring suffix = L"\\Clingfy\\Logs";
  ASSERT_GE(dir.size(), suffix.size());
  EXPECT_EQ(dir.substr(dir.size() - suffix.size()), suffix);
}

TEST(LogLocationsTest, DartLogsDirectoryFallsBackToRunnerRcIdentity) {
  // runner_tests.exe carries no CompanyName/ProductName version strings, so
  // the resolver must fall back to the Runner.rc identity — the same names
  // path_provider derives for the real app.
  const std::wstring dir = DartLogsDirectory();
  ASSERT_FALSE(dir.empty());
  const std::wstring suffix = L"\\com.clingfy\\clingfy\\Logs";
  ASSERT_GE(dir.size(), suffix.size());
  EXPECT_EQ(dir.substr(dir.size() - suffix.size()), suffix);
}

TEST(LogLocationsTest, TodayDartLogFilePathIsAJsonlUnderTheLogsDir) {
  const std::wstring path = TodayDartLogFilePath();
  ASSERT_FALSE(path.empty());
  EXPECT_NE(path.find(L"\\Logs\\logs_"), std::wstring::npos);
  const std::wstring ext = L".jsonl";
  EXPECT_EQ(path.substr(path.size() - ext.size()), ext);
}

}  // namespace
}  // namespace clingfy::storage
