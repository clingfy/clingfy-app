#include "Capture/Export/export_passthrough.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace clingfy::capture::export_ {
namespace {

namespace fs = std::filesystem;

// ---- ResolveExportDestination ----------------------------------------------
//
// Pure path-arithmetic tests; no filesystem dependency. Validates the
// extension / sanitization / collision-avoidance rules that Slice 1
// commits to.

TEST(ResolveExportDestinationTest, AppendsMovExtensionWhenStemHasNone) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "MyRecording");
  EXPECT_NE(dest.find("MyRecording.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, StripsExistingExtensionThenForcesMov) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "MyRecording.mp4");
  EXPECT_NE(dest.find("MyRecording.mov"), std::string::npos);
  EXPECT_EQ(dest.find(".mp4"), std::string::npos);
}

TEST(ResolveExportDestinationTest, KeepsMultiDotStems) {
  // "first.draft" should NOT have ".draft" treated as an extension —
  // the conservative heuristic strips at most one trailing 1-5 char
  // extension and only when no slashes are present.
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "first.draft");
  EXPECT_NE(dest.find("first.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, KeepsLongTrailingTokenAsPartOfStem) {
  // Trailing token longer than 5 chars is not an extension.
  const std::string dest =
      ResolveExportDestination("C:\\Videos", "Recording.session2026");
  EXPECT_NE(dest.find("Recording.session2026.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, FallsBackToUntitledOnEmptyStem) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "");
  EXPECT_NE(dest.find("Untitled.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, FallsBackToUntitledOnWhitespaceStem) {
  const std::string dest =
      ResolveExportDestination("C:\\Users\\me\\Videos", "   \t ");
  EXPECT_NE(dest.find("Untitled.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, SanitizesForbiddenCharacters) {
  const std::string dest = ResolveExportDestination(
      "C:\\Users\\me\\Videos", "a:b*c?d\"e<f>g|h");
  // The sanitizer operates on the *filename* portion only; the
  // directory portion may legally contain a drive-letter colon (`C:`).
  // Extract the leaf name from the resolved destination and check that
  // every forbidden char is gone there.
  const std::string leaf = fs::u8path(dest).filename().u8string();
  for (char ch : std::string(":*?\"<>|")) {
    EXPECT_EQ(leaf.find(ch), std::string::npos)
        << "Forbidden character '" << ch << "' leaked into filename: "
        << leaf;
  }
  EXPECT_NE(leaf.find(".mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, PreservesSpacesInStem) {
  const std::string dest =
      ResolveExportDestination("C:\\Videos", "My Cool Recording");
  EXPECT_NE(dest.find("My Cool Recording.mov"), std::string::npos);
}

TEST(ResolveExportDestinationTest, AvoidsCollisionByAppendingNumber) {
  // Stage a file at the resolved location; the next call should land
  // on "(1).mov" rather than overwrite.
  auto tmp = fs::temp_directory_path() / "clingfy_export_collision_test";
  fs::remove_all(tmp);
  fs::create_directories(tmp);

  const std::string staged = (tmp / "Take.mov").u8string();
  std::ofstream(staged) << "marker";
  ASSERT_TRUE(fs::exists(staged));

  const std::string dest =
      ResolveExportDestination(tmp.u8string(), "Take");
  EXPECT_NE(dest.find("Take (1).mov"), std::string::npos)
      << "actual dest: " << dest;

  fs::remove_all(tmp);
}

// ---- ExportPassthroughCopy (filesystem-touching) ---------------------------
//
// These create a tiny .clingfyproj-shaped scaffold so the project reader
// returns a real screen_path, then verify the copy lands at the expected
// destination.

namespace {
// Unique per-test temp root so the four filesystem tests can't interfere
// with each other when Windows leaves a file lock from a prior run.
fs::path StageProject(const std::string& session_id,
                      const std::string& payload) {
  // Per-session subdir avoids the Windows file-lock race where the
  // previous test's screen.mov hasn't been fully closed by the cmd
  // interpreter yet when the next test starts.
  const auto root = fs::temp_directory_path() /
                    ("clingfy_export_passthrough_test_" + session_id);
  std::error_code ec;
  fs::remove_all(root, ec);
  const auto project = root / (session_id + ".clingfyproj");
  fs::create_directories(project / "capture");

  const std::string manifest = R"({
  "schemaVersion": 2,
  "projectId": ")" + session_id + R"(",
  "createdAt": "2026-05-28T22:00:00.000Z",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json"
  }
})";
  std::ofstream(project / "project.json") << manifest;
  std::ofstream(project / "capture" / "screen.mov") << payload;
  std::ofstream(project / "capture" / "screen.meta.json")
      << R"({"width":1600,"height":900,"fps":30})";
  return project;
}
}  // namespace

TEST(ExportPassthroughCopyTest, CopiesScreenMovToDestination) {
  const auto project = StageProject("export-test-1", "MOCK_VIDEO_BYTES");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "MyExport";
  input.format = "mov";

  const auto outcome = ExportPassthroughCopy(input);
  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;
  EXPECT_FALSE(outcome.output_path.empty());
  EXPECT_TRUE(fs::exists(fs::u8path(outcome.output_path)));
  EXPECT_FALSE(outcome.format_was_downgraded);

  // Payload survived the copy.
  std::ifstream ifs(fs::u8path(outcome.output_path));
  const std::string content((std::istreambuf_iterator<char>(ifs)),
                             std::istreambuf_iterator<char>());
  EXPECT_EQ(content, "MOCK_VIDEO_BYTES");

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, FlagsFormatDowngradeWhenRequestNotMov) {
  const auto project = StageProject("export-test-2", "x");
  const auto dest_dir = project.parent_path() / "out";
  fs::create_directories(dest_dir);

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = dest_dir.u8string();
  input.filename = "MyExport";
  input.format = "mp4";

  const auto outcome = ExportPassthroughCopy(input);
  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;
  EXPECT_TRUE(outcome.format_was_downgraded);
  // The output extension is forced to .mov regardless of requested format.
  EXPECT_NE(outcome.output_path.find(".mov"), std::string::npos);
  EXPECT_EQ(outcome.output_path.find(".mp4"), std::string::npos);

  std::error_code rm_ec;
  fs::remove_all(project.parent_path(), rm_ec);
}

TEST(ExportPassthroughCopyTest, ReturnsInputMissingWhenProjectPathEmpty) {
  PassthroughInput input;
  input.directory_override = "C:\\Videos";
  input.filename = "x";

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_EQ(outcome.error, PassthroughError::kInputMissing);
  EXPECT_FALSE(outcome.message.empty());
}

TEST(ExportPassthroughCopyTest, FallsBackToDefaultSaveFolderWhenDirOverrideEmpty) {
  // Empty directoryOverride no longer fails — it now falls back to the
  // default save folder (mirroring macOS). Point the resolver at a temp
  // dir via the env override so the test never touches the real
  // %USERPROFILE%\Videos\Clingfy.
  const auto fallback_root =
      fs::temp_directory_path() / "clingfy_export_default_folder_test";
  std::error_code ec;
  fs::remove_all(fallback_root, ec);
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER",
                            fallback_root.wstring().c_str());

  const auto project = StageProject("export-test-3", "DEFAULT_FOLDER_BYTES");

  PassthroughInput input;
  input.project_path = project.u8string();
  input.directory_override = "";  // user supplied no folder
  input.filename = "FromDefault";

  const auto outcome = ExportPassthroughCopy(input);
  ::SetEnvironmentVariableW(L"CLINGFY_DEFAULT_SAVE_FOLDER", nullptr);

  ASSERT_EQ(outcome.error, PassthroughError::kNone) << outcome.message;
  EXPECT_FALSE(outcome.output_path.empty());
  EXPECT_NE(outcome.output_path.find("clingfy_export_default_folder_test"),
            std::string::npos)
      << "expected output under the default folder, got: "
      << outcome.output_path;
  EXPECT_TRUE(fs::exists(fs::u8path(outcome.output_path)));

  fs::remove_all(fallback_root, ec);
  fs::remove_all(project.parent_path(), ec);
}

TEST(ExportPassthroughCopyTest, ReturnsInputMissingWhenProjectDoesNotExist) {
  PassthroughInput input;
  input.project_path = "C:\\definitely\\not\\a\\real\\project.clingfyproj";
  input.directory_override = fs::temp_directory_path().u8string();
  input.filename = "x";

  const auto outcome = ExportPassthroughCopy(input);
  EXPECT_EQ(outcome.error, PassthroughError::kInputMissing);
}

}  // namespace
}  // namespace clingfy::capture::export_
