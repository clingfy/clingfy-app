#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

#include "Bridge/method_router.h"
#include "Bridge/native_error_codes.h"
#include "Services/log_locations.h"
#include "Services/shell_reveal.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

namespace fs = std::filesystem;
using test_support::MakeRecorder;
using test_support::RecordedReply;

// Phase 10.1: the storage_router log/reveal handlers are real. These tests
// pin the gating + error-code contract (macOS parity: LOG_FILE_UNAVAILABLE /
// LOG_FILE_NOT_FOUND / FILE_NOT_FOUND). Actual Explorer launches are
// suppressed via the CLINGFY_SUPPRESS_SHELL_OPEN seam; what's under test is
// the decision logic, never the shell.

class StorageRouterRevealTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ::SetEnvironmentVariableW(L"CLINGFY_SUPPRESS_SHELL_OPEN", L"1");
    temp_root_ = fs::temp_directory_path() /
                 L"clingfy_storage_router_reveal_test";
    fs::remove_all(temp_root_);
    dart_logs_dir_ = temp_root_ / L"DartLogs";
    ::SetEnvironmentVariableW(L"CLINGFY_DART_LOG_DIR",
                              dart_logs_dir_.wstring().c_str());
  }

  void TearDown() override {
    ::SetEnvironmentVariableW(L"CLINGFY_DART_LOG_DIR", nullptr);
    ::SetEnvironmentVariableW(L"CLINGFY_SUPPRESS_SHELL_OPEN", nullptr);
    std::error_code ec;
    fs::remove_all(temp_root_, ec);
  }

  RecordedReply Dispatch(const std::string& method) {
    RecordedReply reply;
    router_.Dispatch(
        flutter::MethodCall<flutter::EncodableValue>(
            method, std::make_unique<flutter::EncodableValue>()),
        MakeRecorder(reply));
    return reply;
  }

  RecordedReply DispatchWithArgs(const std::string& method,
                                 flutter::EncodableMap args) {
    RecordedReply reply;
    router_.Dispatch(
        flutter::MethodCall<flutter::EncodableValue>(
            method,
            std::make_unique<flutter::EncodableValue>(std::move(args))),
        MakeRecorder(reply));
    return reply;
  }

  void CreateTodayLogFile() {
    fs::create_directories(dart_logs_dir_);
    const std::wstring today = clingfy::storage::TodayDartLogFilePath();
    std::ofstream f(fs::path(today), std::ios::out | std::ios::binary);
    f << "{}\n";
  }

  MethodRouter router_;
  fs::path temp_root_;
  fs::path dart_logs_dir_;
};

TEST_F(StorageRouterRevealTest, ResolveRevealActionShape) {
  using clingfy::storage::ResolveRevealAction;
  using clingfy::storage::RevealAction;
  EXPECT_EQ(ResolveRevealAction(false, false), RevealAction::kNone);
  EXPECT_EQ(ResolveRevealAction(false, true), RevealAction::kNone);
  EXPECT_EQ(ResolveRevealAction(true, true), RevealAction::kOpenFolder);
  EXPECT_EQ(ResolveRevealAction(true, false), RevealAction::kSelectInFolder);
}

TEST_F(StorageRouterRevealTest, GetTodayLogFilePathUnavailableWithoutDir) {
  const RecordedReply reply = Dispatch("getTodayLogFilePath");
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "LOG_FILE_UNAVAILABLE");
}

TEST_F(StorageRouterRevealTest, GetTodayLogFilePathNotFoundWithoutFile) {
  fs::create_directories(dart_logs_dir_);
  const RecordedReply reply = Dispatch("getTodayLogFilePath");
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "LOG_FILE_NOT_FOUND");
}

TEST_F(StorageRouterRevealTest, GetTodayLogFilePathReturnsExistingFile) {
  CreateTodayLogFile();
  const RecordedReply reply = Dispatch("getTodayLogFilePath");
  ASSERT_TRUE(reply.success_called);
  const auto* path = std::get_if<std::string>(&reply.success_value);
  ASSERT_NE(path, nullptr);
  EXPECT_NE(path->find("logs_"), std::string::npos);
  EXPECT_EQ(path->substr(path->size() - 6), ".jsonl");
}

TEST_F(StorageRouterRevealTest, RevealTodayLogFileGatesLikeGetPath) {
  // No fake success: missing dir and missing file are structured errors.
  RecordedReply reply = Dispatch("revealTodayLogFile");
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "LOG_FILE_UNAVAILABLE");

  fs::create_directories(dart_logs_dir_);
  reply = Dispatch("revealTodayLogFile");
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "LOG_FILE_NOT_FOUND");

  CreateTodayLogFile();
  reply = Dispatch("revealTodayLogFile");
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(StorageRouterRevealTest, RevealLogsFolderRequiresExistingDir) {
  RecordedReply reply = Dispatch("revealLogsFolder");
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "LOG_FILE_UNAVAILABLE");

  fs::create_directories(dart_logs_dir_);
  reply = Dispatch("revealLogsFolder");
  EXPECT_TRUE(reply.success_called);
}

TEST_F(StorageRouterRevealTest, RevealFileRequiresPathArg) {
  const RecordedReply reply = Dispatch("revealFile");
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kBadArgs);
}

TEST_F(StorageRouterRevealTest, RevealFileMissingPathIsFileNotFound) {
  const RecordedReply reply = DispatchWithArgs(
      "revealFile",
      flutter::EncodableMap{
          {flutter::EncodableValue("path"),
           flutter::EncodableValue((temp_root_ / L"nope.mp4").string())},
      });
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kFileNotFound);
}

TEST_F(StorageRouterRevealTest, RevealFileSucceedsForExistingFile) {
  fs::create_directories(temp_root_);
  const fs::path file = temp_root_ / L"export.mp4";
  std::ofstream(file, std::ios::out | std::ios::binary) << "x";
  const RecordedReply reply = DispatchWithArgs(
      "revealFile",
      flutter::EncodableMap{
          {flutter::EncodableValue("path"),
           flutter::EncodableValue(file.string())},
      });
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(StorageRouterRevealTest, RevealTempFolderSucceeds) {
  // %TEMP% always exists on a test box.
  const RecordedReply reply = Dispatch("revealTempFolder");
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(StorageRouterRevealTest, OpenSaveFolderUsesProvidedPath) {
  fs::create_directories(temp_root_);
  const RecordedReply reply = DispatchWithArgs(
      "openSaveFolder",
      flutter::EncodableMap{
          {flutter::EncodableValue("path"),
           flutter::EncodableValue(temp_root_.string())},
      });
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(StorageRouterRevealTest, OpenSaveFolderAlwaysReplies) {
  // No-arg call falls back to the default save folder, which may or may
  // not exist on this box — the contract under test is reply-on-every-path
  // (success, or the structured SAVE_FOLDER_UNAVAILABLE).
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER",
                            (temp_root_ / L"absent").wstring().c_str());
  const RecordedReply reply = Dispatch("openSaveFolder");
  EXPECT_TRUE(reply.success_called || reply.error_called);
  if (reply.error_called) {
    EXPECT_EQ(reply.error_code, "SAVE_FOLDER_UNAVAILABLE");
  }
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER", nullptr);
}

}  // namespace
}  // namespace clingfy::bridge
