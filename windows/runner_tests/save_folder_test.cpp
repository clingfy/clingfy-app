#include "Services/save_folder.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <filesystem>
#include <string>

namespace clingfy::storage {
namespace {

namespace fs = std::filesystem;

constexpr const wchar_t* kOverrideEnv = L"CLINGFY_DEFAULT_SAVE_FOLDER";

bool EndsWith(const std::wstring& value, const std::wstring& suffix) {
  return value.size() >= suffix.size() &&
         value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

TEST(SaveFolderTest, DefaultHonorsEnvOverride) {
  ::SetEnvironmentVariableW(kOverrideEnv, L"D:\\Custom\\Exports");
  EXPECT_EQ(DefaultSaveFolder(), L"D:\\Custom\\Exports");
  ::SetEnvironmentVariableW(kOverrideEnv, nullptr);
}

TEST(SaveFolderTest, DefaultLandsInAClingfySubfolderWhenNoOverride) {
  ::SetEnvironmentVariableW(kOverrideEnv, nullptr);
  const std::wstring folder = DefaultSaveFolder();
  ASSERT_FALSE(folder.empty());
  EXPECT_TRUE(EndsWith(folder, L"\\Clingfy"))
      << "default save folder should end in \\Clingfy";
}

TEST(SaveFolderTest, DefaultUtf8MatchesWide) {
  ::SetEnvironmentVariableW(kOverrideEnv, L"C:\\Tmp\\clingfy_save_utf8");
  EXPECT_EQ(DefaultSaveFolderUtf8(), "C:\\Tmp\\clingfy_save_utf8");
  ::SetEnvironmentVariableW(kOverrideEnv, nullptr);
}

TEST(SaveFolderTest, EnsureDirectoryExistsCreatesNestedPath) {
  const auto root = fs::temp_directory_path() / "clingfy_save_folder_test";
  std::error_code ec;
  fs::remove_all(root, ec);
  const auto nested = root / "a" / "b" / "Clingfy";

  EXPECT_TRUE(EnsureDirectoryExists(nested.wstring()));
  EXPECT_TRUE(fs::exists(nested));
  EXPECT_TRUE(fs::is_directory(nested));
  // Idempotent: a second call on an existing directory still reports true.
  EXPECT_TRUE(EnsureDirectoryExists(nested.wstring()));

  fs::remove_all(root, ec);
}

TEST(SaveFolderTest, EnsureDirectoryExistsRejectsEmptyPath) {
  EXPECT_FALSE(EnsureDirectoryExists(L""));
}

TEST(SaveFolderTest, WideToUtf8RoundTripsAscii) {
  EXPECT_EQ(WideToUtf8(L"C:\\Users\\me\\Videos\\Clingfy"),
            "C:\\Users\\me\\Videos\\Clingfy");
  EXPECT_EQ(WideToUtf8(L""), "");
}

}  // namespace
}  // namespace clingfy::storage
