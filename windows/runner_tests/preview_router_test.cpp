#include "Bridge/method_router.h"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

#include <flutter/encodable_value.h>

#include "test_support.h"

namespace clingfy::bridge {
namespace {

namespace fs = std::filesystem;

using test_support::MakeCallWithArgs;
using test_support::MakeRecorder;
using test_support::RecordedReply;

// Drive the production MethodRouter end-to-end. Same shape as
// router_stub_shapes_test — the test constructs a real router (which
// registers preview_router::RegisterHandlers, including the new
// getRecordingSceneInfo handler) and dispatches a single call.
RecordedReply DispatchWithArgs(const MethodRouter& router,
                               const std::string& method,
                               flutter::EncodableMap args) {
  RecordedReply reply;
  router.Dispatch(MakeCallWithArgs(method, std::move(args)),
                  MakeRecorder(reply));
  return reply;
}

// Minimal `.clingfyproj` fixture: write project.json + the required
// capture/screen.{mov,meta} files. Caller adds camera / cursor / zoom
// on top as needed. Uses the same `schemaVersion: 2` manifest shape the
// reader_test uses, so the two test files share a contract pin.
fs::path MakeMinimalBundle(const fs::path& base, const std::string& name) {
  const fs::path root = base / (name + ".clingfyproj");
  fs::create_directories(root / "capture");

  const std::string manifest = R"({
  "schemaVersion": 2,
  "projectId": ")" + name + R"(",
  "createdAt": "2026-05-26T10:00:00.000Z",
  "updatedAt": "2026-05-26T10:00:00.000Z",
  "displayName": ")" + name + R"(",
  "status": "ready",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json",
    "cursorData": "capture/cursor.json",
    "zoomManual": "capture/zoom.manual.json"
  },
  "camera": {
    "rawVideo": "camera/raw.mov",
    "metadata": "camera/meta.json",
    "segmentsDirectory": "camera/segments"
  },
  "post": {
    "state": "post/state.json",
    "thumbnail": "post/thumbnail.jpg"
  },
  "derived": {
    "waveform": "derived/waveform.json"
  },
  "exportHistory": []
}
)";
  const std::string screen_meta = R"({
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "platform": "windows"
}
)";
  {
    std::ofstream out(root / "project.json", std::ios::binary);
    out << manifest;
  }
  {
    std::ofstream out(root / "capture" / "screen.mov", std::ios::binary);
    out << "fake-screen";
  }
  {
    std::ofstream out(root / "capture" / "screen.meta.json", std::ios::binary);
    out << screen_meta;
  }
  return root;
}

void AddCameraAssets(const fs::path& bundle_root) {
  fs::create_directories(bundle_root / "camera");
  std::ofstream raw(bundle_root / "camera" / "raw.mov", std::ios::binary);
  raw << "fake-camera";
  std::ofstream meta(bundle_root / "camera" / "meta.json", std::ios::binary);
  meta << "{}";
}

class PreviewRouterSceneInfoTest : public ::testing::Test {
 protected:
  void SetUp() override {
    base_ = fs::temp_directory_path() /
            (std::string("clingfy-preview-router-test-") +
             std::to_string(
                 reinterpret_cast<std::uintptr_t>(this)));
    std::error_code ec;
    fs::remove_all(base_, ec);
    fs::create_directories(base_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(base_, ec);
  }

  // Build the EncodableMap that getRecordingSceneInfo expects.
  static flutter::EncodableMap Args(const std::string& project_path_utf8) {
    return flutter::EncodableMap{
        {flutter::EncodableValue("projectPath"),
         flutter::EncodableValue(project_path_utf8)},
    };
  }

  // Convenience: turn a fs::path into the UTF-8 string Dart would hand
  // us. wstring().u8string() doesn't survive every MSVC toolchain;
  // fs::path::string() returns the system-narrow string, which the
  // runtime is configured to be UTF-8 on Windows 10+ since the runner
  // sets `<activeCodePage>UTF-8` in runner.exe.manifest.
  static std::string PathToUtf8(const fs::path& p) {
    return p.string();
  }

  fs::path base_;
};

// ---- BAD_ARGS path --------------------------------------------------

TEST_F(PreviewRouterSceneInfoTest, MissingArgsMapReturnsBadArgs) {
  MethodRouter router;
  RecordedReply reply;
  // No-args invocation — getRecordingSceneInfo expects a map but gets nothing.
  router.Dispatch(test_support::MakeCall("getRecordingSceneInfo"),
                  MakeRecorder(reply));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
  EXPECT_EQ(reply.error_message, "missing projectPath");
}

TEST_F(PreviewRouterSceneInfoTest, MissingProjectPathKeyReturnsBadArgs) {
  MethodRouter router;
  flutter::EncodableMap args;  // empty map — projectPath key absent.
  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      std::move(args));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

TEST_F(PreviewRouterSceneInfoTest, WrongTypeProjectPathReturnsBadArgs) {
  MethodRouter router;
  flutter::EncodableMap args{
      {flutter::EncodableValue("projectPath"), flutter::EncodableValue(42)},
  };
  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      std::move(args));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

// ---- SCENE_INPUT_MISSING — reader-side failures ---------------------

TEST_F(PreviewRouterSceneInfoTest, NonExistentBundleReturnsSceneInputMissing) {
  MethodRouter router;
  const fs::path nonexistent = base_ / "does-not-exist.clingfyproj";
  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(nonexistent)));
  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "SCENE_INPUT_MISSING");
  EXPECT_EQ(reply.error_message,
            "Recording project not found. It may have been moved or deleted.");

  // Details mirror macOS: the projectPath echo.
  ASSERT_TRUE(
      std::holds_alternative<std::string>(reply.error_details));
  EXPECT_EQ(std::get<std::string>(reply.error_details),
            PathToUtf8(nonexistent));
}

TEST_F(PreviewRouterSceneInfoTest, EmptyProjectPathReturnsSceneInputMissing) {
  MethodRouter router;
  const auto reply =
      DispatchWithArgs(router, "getRecordingSceneInfo", Args(""));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "SCENE_INPUT_MISSING");
}

TEST_F(PreviewRouterSceneInfoTest, MalformedManifestReturnsSceneInputMissing) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "malformed");
  // Clobber project.json with broken JSON.
  std::ofstream out(root / "project.json", std::ios::binary);
  out << "{ not valid json";
  out.close();

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "SCENE_INPUT_MISSING");
}

TEST_F(PreviewRouterSceneInfoTest, SchemaDriftReturnsSceneInputMissing) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "drift");
  // Rewrite project.json with schemaVersion: 3.
  std::ofstream out(root / "project.json", std::ios::binary);
  out << R"({"schemaVersion": 3, "status": "ready"})";
  out.close();

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "SCENE_INPUT_MISSING");
}

TEST_F(PreviewRouterSceneInfoTest,
       MissingRequiredScreenFileReturnsSceneInputMissing) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "missing-screen");
  fs::remove(root / "capture" / "screen.mov");

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "SCENE_INPUT_MISSING");
}

// ---- Happy paths ----------------------------------------------------

TEST_F(PreviewRouterSceneInfoTest, HappyPathWithoutCamera) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "no-camera");
  // No camera assets on disk.

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  ASSERT_TRUE(std::holds_alternative<flutter::EncodableMap>(
      reply.success_value));
  const auto& map =
      std::get<flutter::EncodableMap>(reply.success_value);

  auto find = [&](const char* key) -> const flutter::EncodableValue* {
    auto it = map.find(flutter::EncodableValue(key));
    return it == map.end() ? nullptr : &it->second;
  };

  ASSERT_NE(find("projectPath"), nullptr);
  EXPECT_EQ(std::get<std::string>(*find("projectPath")), PathToUtf8(root));

  ASSERT_NE(find("screenPath"), nullptr);
  EXPECT_NE(std::get<std::string>(*find("screenPath")).find("screen.mov"),
            std::string::npos);

  ASSERT_NE(find("metadataPath"), nullptr);
  EXPECT_NE(
      std::get<std::string>(*find("metadataPath")).find("screen.meta.json"),
      std::string::npos);

  // cameraPath absent — Dart parser reads it as null.
  EXPECT_EQ(find("cameraPath"), nullptr);

  // camera key intentionally NOT emitted; matches macOS gotcha #7.
  EXPECT_EQ(find("camera"), nullptr);

  // cameraExportCapabilities map — all five capabilities true.
  ASSERT_NE(find("cameraExportCapabilities"), nullptr);
  ASSERT_TRUE(std::holds_alternative<flutter::EncodableMap>(
      *find("cameraExportCapabilities")));
  const auto& caps = std::get<flutter::EncodableMap>(
      *find("cameraExportCapabilities"));
  for (const char* name :
       {"shapeMask", "cornerRadius", "border", "shadow", "chromaKey"}) {
    auto it = caps.find(flutter::EncodableValue(name));
    ASSERT_NE(it, caps.end()) << name << " missing";
    ASSERT_TRUE(std::holds_alternative<bool>(it->second)) << name;
    EXPECT_TRUE(std::get<bool>(it->second)) << name << " was false";
  }
}

TEST_F(PreviewRouterSceneInfoTest, HappyPathWithCameraEmitsCameraPath) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "with-camera");
  AddCameraAssets(root);

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map =
      std::get<flutter::EncodableMap>(reply.success_value);

  auto it = map.find(flutter::EncodableValue("cameraPath"));
  ASSERT_NE(it, map.end());
  const auto path = std::get<std::string>(it->second);
  EXPECT_NE(path.find("raw.mov"), std::string::npos);
}

// ---- Path / encoding sanity ----------------------------------------

TEST_F(PreviewRouterSceneInfoTest, AbsolutePathsAreEchoedBack) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "abs-paths");
  ASSERT_TRUE(root.is_absolute());

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map =
      std::get<flutter::EncodableMap>(reply.success_value);

  for (const char* key : {"projectPath", "screenPath", "metadataPath"}) {
    auto it = map.find(flutter::EncodableValue(key));
    ASSERT_NE(it, map.end()) << key;
    const auto p = std::get<std::string>(it->second);
    EXPECT_TRUE(fs::path(p).is_absolute()) << key << " was not absolute: " << p;
  }
}

}  // namespace
}  // namespace clingfy::bridge
