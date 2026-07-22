#include "Bridge/method_router.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>

#include "Encoding/audio_sidecar_writer.h"
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

  // This minimal bundle's screen.meta.json has no editorSeed block, so the
  // handler omits the `camera` key and Dart falls back to a hidden camera
  // (backward-compat with pre-editorSeed recordings). See
  // EditorSeedSurfacesAsCameraBlock for the populated path.
  EXPECT_EQ(find("camera"), nullptr);

  // cameraExportCapabilities map. Phase 9.4 added shapeMask + cornerRadius; 9.5
  // adds border + shadow; 9.7 adds chromaKey. All keys must be present so the
  // Dart parser reads explicit values rather than defaulting.
  ASSERT_NE(find("cameraExportCapabilities"), nullptr);
  ASSERT_TRUE(std::holds_alternative<flutter::EncodableMap>(
      *find("cameraExportCapabilities")));
  const auto& caps = std::get<flutter::EncodableMap>(
      *find("cameraExportCapabilities"));
  auto cap = [&](const char* name) -> bool {
    auto it = caps.find(flutter::EncodableValue(name));
    EXPECT_NE(it, caps.end()) << name << " missing";
    EXPECT_TRUE(std::holds_alternative<bool>(it->second)) << name;
    return std::get<bool>(it->second);
  };
  EXPECT_TRUE(cap("shapeMask"));
  EXPECT_TRUE(cap("cornerRadius"));
  EXPECT_TRUE(cap("border"));
  EXPECT_TRUE(cap("shadow"));
  EXPECT_TRUE(cap("chromaKey"));

  // Audio separation (D10): no sidecars → the legacy-metadata fallback.
  // This bundle's meta has no micActive/loopbackActive/audioSamplesWritten
  // (defaults false/0 — no audio was captured), so both keys are explicit
  // false.
  ASSERT_NE(find("hasMicAudio"), nullptr);
  ASSERT_TRUE(std::holds_alternative<bool>(*find("hasMicAudio")));
  EXPECT_FALSE(std::get<bool>(*find("hasMicAudio")));
  ASSERT_NE(find("hasSystemAudio"), nullptr);
  ASSERT_TRUE(std::holds_alternative<bool>(*find("hasSystemAudio")));
  EXPECT_FALSE(std::get<bool>(*find("hasSystemAudio")));
}

TEST_F(PreviewRouterSceneInfoTest, LegacyPremixRecordingReportsMetadataAudio) {
  // Sidecar-less (pre-separation) recording whose premix carried mic
  // audio: the D10 keys must come from screen.meta.json — reporting false
  // here would disable gain/volume sliders that WORK on the premix.
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "legacy-premix");
  {
    std::ofstream out(root / "capture" / "screen.meta.json",
                      std::ios::binary);
    out << R"({
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "audioSamplesWritten": 480000,
  "micActive": true,
  "loopbackActive": false,
  "platform": "windows"
}
)";
  }

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map = std::get<flutter::EncodableMap>(reply.success_value);
  auto get_bool = [&](const char* key) {
    auto it = map.find(flutter::EncodableValue(key));
    EXPECT_NE(it, map.end()) << key;
    return it != map.end() && std::holds_alternative<bool>(it->second) &&
           std::get<bool>(it->second);
  };
  EXPECT_TRUE(get_bool("hasMicAudio"));
  EXPECT_FALSE(get_bool("hasSystemAudio"));
  // Whole-track gain works on any legacy premix audio.
  EXPECT_TRUE(get_bool("micGainApplies"));
}

TEST_F(PreviewRouterSceneInfoTest,
       LegacyLoopbackOnlyPremixStillHasWorkingGain) {
  // Legacy premix with ONLY system audio: whole-track gain (and normalize)
  // genuinely amplify the premix, so micGainApplies must be true even
  // though the mic never recorded — unlike the separated case, where gain
  // is mic-only and inert.
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "legacy-loopback");
  {
    std::ofstream out(root / "capture" / "screen.meta.json",
                      std::ios::binary);
    out << R"({
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "audioSamplesWritten": 480000,
  "micActive": false,
  "loopbackActive": true,
  "platform": "windows"
}
)";
  }
  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map = std::get<flutter::EncodableMap>(reply.success_value);
  auto get_bool = [&](const char* key) {
    auto it = map.find(flutter::EncodableValue(key));
    EXPECT_NE(it, map.end()) << key;
    return it != map.end() && std::holds_alternative<bool>(it->second) &&
           std::get<bool>(it->second);
  };
  EXPECT_FALSE(get_bool("hasMicAudio"));
  EXPECT_TRUE(get_bool("hasSystemAudio"));
  EXPECT_TRUE(get_bool("micGainApplies"));
}

TEST_F(PreviewRouterSceneInfoTest, MacBundleMetadataOmitsAudioKeys) {
  // A macOS bundle's screen.meta.json has a different shape — its
  // micActive/audioSamplesWritten parse to defaults here, so gating on
  // them would report false/false and disable sliders that WORK on the mac
  // premix. The keys must be OMITTED (Dart falls back to its legacy device
  // gate) whenever the metadata isn't Windows-authored.
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "mac-bundle");
  {
    std::ofstream out(root / "capture" / "screen.meta.json",
                      std::ios::binary);
    out << R"({
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "platform": "macos"
}
)";
  }
  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map = std::get<flutter::EncodableMap>(reply.success_value);
  EXPECT_EQ(map.find(flutter::EncodableValue("hasMicAudio")), map.end());
  EXPECT_EQ(map.find(flutter::EncodableValue("hasSystemAudio")), map.end());
  EXPECT_EQ(map.find(flutter::EncodableValue("micGainApplies")), map.end());
}

TEST_F(PreviewRouterSceneInfoTest, DecodableSystemSidecarDisablesMicGain) {
  // SEPARATED recording with only a system sidecar: audio is present
  // (volume works) but gain/normalize are mic-only and inert — the reply
  // must say hasSystemAudio=true, micGainApplies=false so the sidebar
  // disables the gain row instead of promising an effect the pipeline
  // ignores. Uses a REAL AAC sidecar via the recorder's own writer.
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "sep-system-only");
  {
    std::ofstream manifest(root / "project.json", std::ios::binary);
    manifest << R"({
  "schemaVersion": 2,
  "projectId": "sep-system-only",
  "status": "ready",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json",
    "systemAudio": "capture/system.m4a"
  }
})";
  }
  {
    clingfy::encoding::AudioSidecarWriter writer;
    const fs::path tmp = root / "capture" / "system.tmp.mp4";
    if (auto err = writer.Open(tmp.string())) {
      GTEST_SKIP() << "AAC sink writer unavailable: " << err->message;
    }
    std::vector<std::int16_t> packet(480 * 2, 900);
    std::int64_t ts = 0;
    for (int i = 0; i < 10; ++i) {
      ASSERT_FALSE(writer.WriteSamples(packet.data(), 480, ts).has_value());
      ts += 100'000;
    }
    ASSERT_FALSE(writer.Finalize().has_value());
    std::error_code mv_ec;
    fs::rename(tmp, root / "capture" / "system.m4a", mv_ec);
    ASSERT_FALSE(mv_ec) << mv_ec.message();
  }

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map = std::get<flutter::EncodableMap>(reply.success_value);
  auto get_bool = [&](const char* key) {
    auto it = map.find(flutter::EncodableValue(key));
    EXPECT_NE(it, map.end()) << key;
    return it != map.end() && std::holds_alternative<bool>(it->second) &&
           std::get<bool>(it->second);
  };
  EXPECT_FALSE(get_bool("hasMicAudio"));
  EXPECT_TRUE(get_bool("hasSystemAudio"));
  EXPECT_FALSE(get_bool("micGainApplies"));
}

TEST_F(PreviewRouterSceneInfoTest, UndecodableSidecarReportsNoMicAudio) {
  // The manifest names a mic sidecar and the file EXISTS, but it's junk —
  // the D10 keys ride the decode probe, not bare existence, so the reply
  // must still say false (the sidebar must not enable a gain slider the
  // export would ignore).
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "junk-mic");
  {
    std::ofstream manifest(root / "project.json", std::ios::binary);
    manifest << R"({
  "schemaVersion": 2,
  "projectId": "junk-mic",
  "status": "ready",
  "capture": {
    "screenVideo": "capture/screen.mov",
    "screenMetadata": "capture/screen.meta.json",
    "micAudio": "capture/mic.m4a"
  }
})";
  }
  {
    std::ofstream mic(root / "capture" / "mic.m4a", std::ios::binary);
    mic << "not an mpeg-4 container";
  }

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map = std::get<flutter::EncodableMap>(reply.success_value);
  auto it = map.find(flutter::EncodableValue("hasMicAudio"));
  ASSERT_NE(it, map.end());
  EXPECT_FALSE(std::get<bool>(it->second));
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

TEST_F(PreviewRouterSceneInfoTest, EditorSeedSurfacesAsCameraBlock) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "with-seed");
  AddCameraAssets(root);
  // Overwrite screen.meta.json with an editorSeed (macOS on-disk `camera*`
  // keys) — the recording engine writes this at stop; here we pin that the
  // handler surfaces it as the UN-prefixed `camera` block Dart consumes.
  {
    std::ofstream out(root / "capture" / "screen.meta.json", std::ios::binary);
    out << R"({
  "width": 1920, "height": 1080, "fps": 60, "platform": "windows",
  "editorSeed": {
    "cameraVisible": true,
    "cameraLayoutPreset": "overlayBottomRight",
    "cameraShape": "roundedRect",
    "cameraCornerRadius": 0.2,
    "cameraOpacity": 0.85,
    "cameraMirror": false,
    "cameraShadow": 2,
    "cameraBorderWidth": 4,
    "cameraBorderColorArgb": 4294967295
  }
})";
  }

  const auto reply = DispatchWithArgs(router, "getRecordingSceneInfo",
                                      Args(PathToUtf8(root)));
  ASSERT_TRUE(reply.success_called);
  const auto& map = std::get<flutter::EncodableMap>(reply.success_value);
  auto it = map.find(flutter::EncodableValue("camera"));
  ASSERT_NE(it, map.end());
  ASSERT_TRUE(std::holds_alternative<flutter::EncodableMap>(it->second));
  const auto& cam = std::get<flutter::EncodableMap>(it->second);
  auto field = [&](const char* key) -> const flutter::EncodableValue* {
    auto f = cam.find(flutter::EncodableValue(key));
    return f == cam.end() ? nullptr : &f->second;
  };
  // Keys are UN-prefixed; the disk `cameraShadow` is renamed to shadowPreset.
  ASSERT_NE(field("visible"), nullptr);
  EXPECT_TRUE(std::get<bool>(*field("visible")));
  ASSERT_NE(field("shape"), nullptr);
  EXPECT_EQ(std::get<std::string>(*field("shape")), "roundedRect");
  ASSERT_NE(field("layoutPreset"), nullptr);
  EXPECT_EQ(std::get<std::string>(*field("layoutPreset")), "overlayBottomRight");
  ASSERT_NE(field("mirror"), nullptr);
  EXPECT_FALSE(std::get<bool>(*field("mirror")));
  ASSERT_NE(field("shadowPreset"), nullptr);
  EXPECT_EQ(std::get<int>(*field("shadowPreset")), 2);
  // The on-disk key name must NOT leak through into the reply.
  EXPECT_EQ(field("cameraShadow"), nullptr);
  // ARGB survives the bridge as int64 (4294967295 > INT32_MAX).
  ASSERT_NE(field("borderColorArgb"), nullptr);
  EXPECT_EQ(std::get<std::int64_t>(*field("borderColorArgb")),
            std::int64_t{4294967295});
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

// ====================================================================
// previewOpen / previewClose router contract.
//
// The full happy path (texture allocation, MediaPlayer setup,
// VideoFrameAvailable subscription) requires a live Flutter
// TextureRegistrar — only available in the running app, not in
// runner_tests. These tests therefore focus on the contract surface
// the bridge exposes BEFORE the engine itself runs: argument
// validation, manifest-resolution failures, the PREVIEW_INPUT_MISSING
// error shape, and previewClose's silent stale-session no-op. The
// open/close lifecycle was stress-tested manually against the live
// runner during this PR (build/windows-poc/stage2a_2_native.log
// confirms the UnregisterExternalTexture callback fires cleanly on
// Intel Iris Xe).
// ====================================================================

class PreviewRouterOpenCloseTest : public PreviewRouterSceneInfoTest {
 protected:
  static flutter::EncodableMap OpenArgsMap(const std::string& session_id,
                                           const std::string& project_path) {
    flutter::EncodableMap m;
    if (!session_id.empty()) {
      m[flutter::EncodableValue("sessionId")] =
          flutter::EncodableValue(session_id);
    }
    if (!project_path.empty()) {
      m[flutter::EncodableValue("projectPath")] =
          flutter::EncodableValue(project_path);
    }
    return m;
  }

  static flutter::EncodableMap CloseArgsMap(const std::string& session_id) {
    flutter::EncodableMap m;
    m[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(session_id);
    return m;
  }
};

// ---- previewOpen BAD_ARGS ------------------------------------------

TEST_F(PreviewRouterOpenCloseTest, OpenMissingArgsReturnsBadArgs) {
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(test_support::MakeCall("previewOpen"), MakeRecorder(reply));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

TEST_F(PreviewRouterOpenCloseTest, OpenMissingSessionIdReturnsBadArgs) {
  MethodRouter router;
  const auto reply = DispatchWithArgs(
      router, "previewOpen",
      OpenArgsMap(/*session_id=*/"", "C:\\some\\path.clingfyproj"));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

TEST_F(PreviewRouterOpenCloseTest, OpenMissingProjectPathReturnsBadArgs) {
  MethodRouter router;
  const auto reply = DispatchWithArgs(
      router, "previewOpen", OpenArgsMap("sess-1", /*project_path=*/""));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

// ---- previewOpen PREVIEW_INPUT_MISSING -----------------------------

TEST_F(PreviewRouterOpenCloseTest, OpenNonexistentBundleReturnsPreviewInputMissing) {
  MethodRouter router;
  const fs::path nonexistent = base_ / "missing.clingfyproj";
  const auto reply = DispatchWithArgs(
      router, "previewOpen",
      OpenArgsMap("sess-1", PathToUtf8(nonexistent)));

  ASSERT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "PREVIEW_INPUT_MISSING");
  EXPECT_EQ(reply.error_message,
            "Recording project not found. It may have been moved or deleted.");
  ASSERT_TRUE(std::holds_alternative<std::string>(reply.error_details));
  EXPECT_EQ(std::get<std::string>(reply.error_details),
            PathToUtf8(nonexistent));
}

TEST_F(PreviewRouterOpenCloseTest, OpenSchemaDriftReturnsPreviewInputMissing) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "open-schema-drift");
  std::ofstream out(root / "project.json", std::ios::binary);
  out << R"({"schemaVersion": 99, "status": "ready"})";
  out.close();

  const auto reply = DispatchWithArgs(
      router, "previewOpen", OpenArgsMap("sess-1", PathToUtf8(root)));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "PREVIEW_INPUT_MISSING");
}

TEST_F(PreviewRouterOpenCloseTest, OpenMissingScreenReturnsPreviewInputMissing) {
  MethodRouter router;
  const fs::path root = MakeMinimalBundle(base_, "open-missing-screen");
  fs::remove(root / "capture" / "screen.mov");

  const auto reply = DispatchWithArgs(
      router, "previewOpen", OpenArgsMap("sess-1", PathToUtf8(root)));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "PREVIEW_INPUT_MISSING");
}

// ---- previewClose contract -----------------------------------------

TEST_F(PreviewRouterOpenCloseTest, CloseAlwaysReplyNull) {
  // previewClose is documented to silently no-op on stale session
  // and on a not-running engine. The handler always reply::Null.
  MethodRouter router;
  const auto reply =
      DispatchWithArgs(router, "previewClose", CloseArgsMap("unknown-session"));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(PreviewRouterOpenCloseTest, CloseWithNoArgsReplyNull) {
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(test_support::MakeCall("previewClose"), MakeRecorder(reply));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

// ---- POC alias removal confirmation --------------------------------

TEST_F(PreviewRouterOpenCloseTest, PocStage2aStartIsNoLongerRegistered) {
  // Confirms Step 5.3 cleanup: the deprecated aliases were removed
  // from preview_router along with the debug screen. Calls now flow
  // through the default not-implemented path.
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(test_support::MakeCall("pocStage2aStart"),
                  MakeRecorder(reply));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "WINDOWS_NOT_IMPLEMENTED");
}

TEST_F(PreviewRouterOpenCloseTest, PocStage2aStopIsNoLongerRegistered) {
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(test_support::MakeCall("pocStage2aStop"),
                  MakeRecorder(reply));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "WINDOWS_NOT_IMPLEMENTED");
}

// ====================================================================
// previewPlay / previewPause / previewSeekTo router contract (5.5).
//
// The router-level tests focus on the contract surface: argument
// validation and the macOS-style "stale session = silent success"
// behaviour. The full happy-path engine interaction (MediaPlayer.Play
// actually plays, PlaybackSession.Position actually seeks) requires a
// live MediaPlayer + Flutter TextureRegistrar that the test process
// doesn't have — that path is validated manually against the running
// runner. The unit tests therefore exercise the "no session is open"
// case for each method, which exercises the same code path as a stale
// session id in production (PreviewEngine returns early before
// touching MediaPlayer).
// ====================================================================

class PreviewRouterTransportTest : public PreviewRouterSceneInfoTest {
 protected:
  static flutter::EncodableMap PlayPauseArgs(const std::string& session_id) {
    flutter::EncodableMap m;
    m[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(session_id);
    return m;
  }

  static flutter::EncodableMap SeekArgs(const std::string& session_id,
                                        std::int64_t ms) {
    flutter::EncodableMap m;
    m[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(session_id);
    m[flutter::EncodableValue("ms")] = flutter::EncodableValue(ms);
    return m;
  }
};

// ---- previewPlay --------------------------------------------------

TEST_F(PreviewRouterTransportTest, PlayMissingArgsReturnsBadArgs) {
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(test_support::MakeCall("previewPlay"), MakeRecorder(reply));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

TEST_F(PreviewRouterTransportTest, PlayMissingSessionIdReturnsBadArgs) {
  MethodRouter router;
  const auto reply =
      DispatchWithArgs(router, "previewPlay", flutter::EncodableMap{});
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
  EXPECT_EQ(reply.error_message, "missing sessionId");
}

TEST_F(PreviewRouterTransportTest, PlayStaleSessionReturnsSuccessNull) {
  // No session is open in the test process; the engine returns early
  // (no MediaPlayer touch) and the router replies null. This is the
  // same code path a stale session id hits in production.
  MethodRouter router;
  const auto reply =
      DispatchWithArgs(router, "previewPlay", PlayPauseArgs("sess-stale"));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

// ---- previewPause -------------------------------------------------

TEST_F(PreviewRouterTransportTest, PauseMissingSessionIdReturnsBadArgs) {
  MethodRouter router;
  const auto reply =
      DispatchWithArgs(router, "previewPause", flutter::EncodableMap{});
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

TEST_F(PreviewRouterTransportTest, PauseStaleSessionReturnsSuccessNull) {
  MethodRouter router;
  const auto reply = DispatchWithArgs(router, "previewPause",
                                      PlayPauseArgs("sess-stale"));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

// ---- previewSetColorGrade (editing port, PR-2b) --------------------

TEST_F(PreviewRouterTransportTest, SetColorGradeWithoutArgsRepliesNull) {
  // Matches the void Dart contract (and HandlePreviewSetCameraPlacement):
  // malformed/missing args are ignored, the reply is always success-null.
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(test_support::MakeCall("previewSetColorGrade"),
                  MakeRecorder(reply));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(PreviewRouterTransportTest, SetColorGradeStaleSessionRepliesNull) {
  // No preview session is open in the test process, so the engine drops the
  // grade silently (stale-session contract) and the router replies null —
  // the same path a slider tick racing a Close hits in production.
  MethodRouter router;
  flutter::EncodableMap grade_map;
  grade_map[flutter::EncodableValue("saturation")] =
      flutter::EncodableValue(-1.0);
  flutter::EncodableMap args;
  args[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(std::string("sess-stale"));
  args[flutter::EncodableValue("colorGrade")] =
      flutter::EncodableValue(grade_map);
  const auto reply = DispatchWithArgs(router, "previewSetColorGrade", args);
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

// ---- previewSetClips (editing port, step 4-1) ---------------------

TEST_F(PreviewRouterTransportTest, SetClipsWithoutArgsRepliesNull) {
  // Void Dart contract: missing/malformed args are ignored, reply is null.
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(test_support::MakeCall("previewSetClips"),
                  MakeRecorder(reply));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(PreviewRouterTransportTest, SetClipsStaleSessionRepliesNull) {
  // No preview session is open in the test process, so the engine drops the
  // clips silently (stale-session contract) and the router replies null — the
  // same path a clip edit racing a Close hits in production. Also exercises the
  // shared clips parser end-to-end (a real reorder list).
  MethodRouter router;
  flutter::EncodableMap clip_b;
  clip_b[flutter::EncodableValue("sourceInMs")] =
      flutter::EncodableValue(std::int64_t{6000});
  clip_b[flutter::EncodableValue("sourceOutMs")] =
      flutter::EncodableValue(std::int64_t{8000});
  clip_b[flutter::EncodableValue("enabled")] = flutter::EncodableValue(true);
  flutter::EncodableMap clip_a;
  clip_a[flutter::EncodableValue("sourceInMs")] =
      flutter::EncodableValue(std::int64_t{0});
  clip_a[flutter::EncodableValue("sourceOutMs")] =
      flutter::EncodableValue(std::int64_t{2000});
  clip_a[flutter::EncodableValue("enabled")] = flutter::EncodableValue(true);
  flutter::EncodableMap args;
  args[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(std::string("sess-stale"));
  args[flutter::EncodableValue("clips")] = flutter::EncodableValue(
      flutter::EncodableList{flutter::EncodableValue(clip_b),
                             flutter::EncodableValue(clip_a)});
  const auto reply = DispatchWithArgs(router, "previewSetClips", args);
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

// ---- previewSeekTo ------------------------------------------------

TEST_F(PreviewRouterTransportTest, SeekToMissingSessionIdReturnsBadArgs) {
  MethodRouter router;
  flutter::EncodableMap args;
  args[flutter::EncodableValue("ms")] =
      flutter::EncodableValue(std::int64_t{1234});
  const auto reply =
      DispatchWithArgs(router, "previewSeekTo", std::move(args));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

TEST_F(PreviewRouterTransportTest, SeekToMissingMsReturnsBadArgs) {
  MethodRouter router;
  const auto reply = DispatchWithArgs(router, "previewSeekTo",
                                      PlayPauseArgs("sess-1"));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
  EXPECT_EQ(reply.error_message, "missing ms");
}

TEST_F(PreviewRouterTransportTest, SeekToWrongTypeMsReturnsBadArgs) {
  MethodRouter router;
  flutter::EncodableMap args;
  args[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(std::string("sess-1"));
  // Double is rejected — the channel contract is integer milliseconds.
  args[flutter::EncodableValue("ms")] = flutter::EncodableValue(1234.5);
  const auto reply =
      DispatchWithArgs(router, "previewSeekTo", std::move(args));
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, "BAD_ARGS");
}

TEST_F(PreviewRouterTransportTest, SeekToStaleSessionReturnsSuccessNull) {
  MethodRouter router;
  const auto reply = DispatchWithArgs(router, "previewSeekTo",
                                      SeekArgs("sess-stale", 1234));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST_F(PreviewRouterTransportTest, SeekToAcceptsInt32Ms) {
  // Some Dart/EncodableValue paths emit int32 instead of int64 for
  // small values. The router should accept both for resilience.
  MethodRouter router;
  flutter::EncodableMap args;
  args[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(std::string("sess-stale"));
  args[flutter::EncodableValue("ms")] =
      flutter::EncodableValue(std::int32_t{42});
  const auto reply =
      DispatchWithArgs(router, "previewSeekTo", std::move(args));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

// Phase 4 preview WYSIWYG: previewSetVoiceCleanup is wired (no longer a no-op)
// and parses the nested {enabled, mode} map. With no live session the engine
// drops it (stale-session guard), so the router still replies a clean null —
// this pins the handler registration + nested-map parse without an engine.
TEST(PreviewRouterVoiceCleanupTest, ParsesNestedMapAndRepliesNullWithNoSession) {
  MethodRouter router;
  flutter::EncodableMap voice;
  voice[flutter::EncodableValue("enabled")] = flutter::EncodableValue(true);
  voice[flutter::EncodableValue("mode")] =
      flutter::EncodableValue(std::string("balanced"));
  flutter::EncodableMap args;
  args[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(std::string("no-such-session"));
  args[flutter::EncodableValue("voiceCleanup")] =
      flutter::EncodableValue(std::move(voice));

  const auto reply =
      DispatchWithArgs(router, "previewSetVoiceCleanup", std::move(args));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

TEST(PreviewRouterVoiceCleanupTest, MissingVoiceCleanupMapStillRepliesNull) {
  MethodRouter router;
  flutter::EncodableMap args;
  args[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(std::string("no-such-session"));
  const auto reply =
      DispatchWithArgs(router, "previewSetVoiceCleanup", std::move(args));
  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
}

}  // namespace
}  // namespace clingfy::bridge
