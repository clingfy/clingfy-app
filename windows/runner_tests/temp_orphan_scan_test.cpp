#include "Services/temp_orphan_scan.h"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace clingfy::storage {
namespace {

namespace fs = std::filesystem;

// Phase 10.1: crash-mid-recording detection — `clingfy_*` strands in %TEMP%
// are counted (never deleted) and reported at startup.

class TempOrphanScanTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = fs::temp_directory_path() / L"clingfy_orphan_scan_test";
    fs::remove_all(dir_);
    fs::create_directories(dir_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }

  void Touch(const std::wstring& name, const std::string& content) {
    std::ofstream f(dir_ / name, std::ios::out | std::ios::binary);
    f << content;
  }

  fs::path dir_;
};

TEST_F(TempOrphanScanTest, CountsOnlyClingfyPrefixedFiles) {
  Touch(L"clingfy_abc123.mp4", "0123456789");          // 10 bytes
  Touch(L"clingfy_abc123.cursor.jsonl", "01234");      // 5 bytes
  Touch(L"unrelated.txt", "xxxx");
  Touch(L"notclingfy_y.mp4", "xxxx");

  const auto result = ScanClingfyTempOrphans(dir_.wstring());
  EXPECT_EQ(result.file_count, 2);
  EXPECT_EQ(result.total_bytes, 15u);
}

TEST_F(TempOrphanScanTest, EmptyDirYieldsZero) {
  const auto result = ScanClingfyTempOrphans(dir_.wstring());
  EXPECT_EQ(result.file_count, 0);
  EXPECT_EQ(result.total_bytes, 0u);
}

TEST_F(TempOrphanScanTest, MissingDirYieldsZeroNotError) {
  const auto result =
      ScanClingfyTempOrphans((dir_ / L"does_not_exist").wstring());
  EXPECT_EQ(result.file_count, 0);
  EXPECT_EQ(result.total_bytes, 0u);
}

TEST_F(TempOrphanScanTest, SubdirectoriesAreIgnored) {
  fs::create_directories(dir_ / L"clingfy_dirlike");
  const auto result = ScanClingfyTempOrphans(dir_.wstring());
  EXPECT_EQ(result.file_count, 0);
}

}  // namespace
}  // namespace clingfy::storage
