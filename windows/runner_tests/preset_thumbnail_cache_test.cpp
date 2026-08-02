#include "Capture/Background/preset_thumbnail_cache.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <cstdlib>
#include <filesystem>
#include <string>

#include "Capture/Background/canvas_preset_renderer.h"

namespace clingfy::capture::background {
namespace {

namespace fs = std::filesystem;

bool PixelTestsRequired() {
  char* required = nullptr;
  size_t len = 0;
  _dupenv_s(&required, &len, "CLINGFY_REQUIRE_PIXEL_TESTS");
  const bool require = required != nullptr && std::string(required) == "1";
  free(required);
  return require;
}

#define SKIP_OR_FAIL(msg)            \
  do {                               \
    if (PixelTestsRequired()) {      \
      FAIL() << "CANARY: " << (msg); \
    } else {                         \
      GTEST_SKIP() << (msg);         \
    }                                \
  } while (false)

CanvasPresetSpec Spec(const char* preset_id = "abstractWaves",
                      const char* palette = "bluePurple") {
  CanvasPresetSpec s;
  s.preset_id = preset_id;
  s.palette_id = palette;
  s.intensity = 0.7;
  s.blur = 0.35;
  s.seed = 1;
  return s;
}

// Points the cache at a scratch directory for the duration of a test, so a run
// never reads or writes the developer's real %LOCALAPPDATA% cache.
class ScopedThumbnailRoot {
 public:
  ScopedThumbnailRoot() {
    dir_ = fs::temp_directory_path() /
           ("clingfy_thumb_test_" + std::to_string(::GetCurrentProcessId()) +
            "_" + std::to_string(counter_++));
    std::error_code ec;
    fs::create_directories(dir_, ec);
    ::SetEnvironmentVariableW(L"CLINGFY_PRESET_THUMBNAIL_ROOT",
                              dir_.wstring().c_str());
  }
  ~ScopedThumbnailRoot() {
    ::SetEnvironmentVariableW(L"CLINGFY_PRESET_THUMBNAIL_ROOT", nullptr);
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }
  const fs::path& path() const { return dir_; }

 private:
  fs::path dir_;
  static inline int counter_ = 0;
};

// ---------------------------------------------------------------------------
// Filename derivation — pure, no GPU.
// ---------------------------------------------------------------------------

// The name IS the cache key. If two different presets could produce the same
// name, one would silently show the other's art.
TEST(PresetThumbnailNameTest, DistinguishesEveryPixelAffectingInput) {
  const std::string base = PresetThumbnailFileName(Spec(), 72, 48);

  EXPECT_NE(base, PresetThumbnailFileName(Spec("graphicMesh"), 72, 48));
  EXPECT_NE(base, PresetThumbnailFileName(Spec("radialGlow"), 72, 48));
  EXPECT_NE(base,
            PresetThumbnailFileName(Spec("abstractWaves", "sunset"), 72, 48));
  EXPECT_NE(base, PresetThumbnailFileName(Spec(), 144, 96));

  CanvasPresetSpec other = Spec();
  other.intensity = 0.71;
  EXPECT_NE(base, PresetThumbnailFileName(other, 72, 48));
  other = Spec();
  other.blur = 0.36;
  EXPECT_NE(base, PresetThumbnailFileName(other, 72, 48));
  other = Spec();
  other.seed = 2;
  EXPECT_NE(base, PresetThumbnailFileName(other, 72, 48));
}

TEST(PresetThumbnailNameTest, IsStableForTheSameInputs) {
  EXPECT_EQ(PresetThumbnailFileName(Spec(), 72, 48),
            PresetThumbnailFileName(Spec(), 72, 48));
}

// The key is built for comparison and contains separators Windows rejects in a
// filename. Creating the file would fail outright if any survived.
TEST(PresetThumbnailNameTest, ContainsNoIllegalPathCharacters) {
  const std::string name = PresetThumbnailFileName(Spec(), 72, 48);
  for (const char c : name) {
    EXPECT_EQ(std::string("<>:\"/\\|?*").find(c), std::string::npos)
        << "illegal character '" << c << "' in " << name;
  }
  EXPECT_NE(name.find(".png"), std::string::npos);
}

// The renderer version rides in the key, so changing the renderer invalidates
// every thumbnail on disk instead of showing pre-change art beside post-change
// backgrounds. Cheapest way to assert it is present at all.
TEST(PresetThumbnailNameTest, CarriesTheRendererVersion) {
  const std::string name = PresetThumbnailFileName(Spec(), 72, 48);
  EXPECT_EQ(name.rfind("v" + std::to_string(kCanvasPresetRendererVersion), 0),
            0u)
      << name;
}

// ---------------------------------------------------------------------------
// Rendering + caching — needs a GPU.
// ---------------------------------------------------------------------------

TEST(PresetThumbnailCacheTest, RendersAPngOnFirstRequest) {
  ScopedThumbnailRoot root;
  const std::string path = EnsurePresetThumbnail(Spec(), 72, 48);
  if (path.empty()) SKIP_OR_FAIL("no usable GPU for thumbnail rendering");

  ASSERT_TRUE(fs::exists(fs::path(path)));
  EXPECT_GT(fs::file_size(fs::path(path)), 0u);
  // Written inside the configured root, not the real AppData cache.
  EXPECT_EQ(fs::path(path).parent_path(), root.path());
}

// THE point of the cache: a second request must not re-render. If it did, the
// picker would run the full renderer per rebuild and the disk write would be
// pure cost.
TEST(PresetThumbnailCacheTest, ASecondRequestReusesTheFile) {
  ScopedThumbnailRoot root;
  const std::string first = EnsurePresetThumbnail(Spec(), 72, 48);
  if (first.empty()) SKIP_OR_FAIL("no usable GPU for thumbnail rendering");

  const auto written_at = fs::last_write_time(fs::path(first));
  const std::string second = EnsurePresetThumbnail(Spec(), 72, 48);

  EXPECT_EQ(second, first);
  EXPECT_EQ(fs::last_write_time(fs::path(second)), written_at)
      << "the file was rewritten, so the render ran again";
}

// Two presets must not collide on disk, which is the file-level restatement of
// the bug where all three ids rendered the same picture.
TEST(PresetThumbnailCacheTest, DifferentPresetsProduceDifferentFiles) {
  ScopedThumbnailRoot root;
  const std::string waves = EnsurePresetThumbnail(Spec("abstractWaves"), 72, 48);
  if (waves.empty()) SKIP_OR_FAIL("no usable GPU for thumbnail rendering");
  const std::string mesh = EnsurePresetThumbnail(Spec("graphicMesh"), 72, 48);
  ASSERT_FALSE(mesh.empty());

  EXPECT_NE(waves, mesh);
  EXPECT_TRUE(fs::exists(fs::path(waves)));
  EXPECT_TRUE(fs::exists(fs::path(mesh)));
}

// A degenerate size must be refused rather than creating a 0-byte PNG the UI
// would then try to decode.
TEST(PresetThumbnailCacheTest, RefusesADegenerateSize) {
  ScopedThumbnailRoot root;
  EXPECT_TRUE(EnsurePresetThumbnail(Spec(), 0, 48).empty());
  EXPECT_TRUE(EnsurePresetThumbnail(Spec(), 72, 0).empty());
}

// No leftover .tmp files: the write goes to a temp name and is renamed into
// place, so a directory listing after a successful render holds only PNGs.
TEST(PresetThumbnailCacheTest, LeavesNoTemporaryFilesBehind) {
  ScopedThumbnailRoot root;
  const std::string path = EnsurePresetThumbnail(Spec(), 72, 48);
  if (path.empty()) SKIP_OR_FAIL("no usable GPU for thumbnail rendering");

  for (const auto& entry : fs::directory_iterator(root.path())) {
    EXPECT_EQ(entry.path().extension().string(), ".png")
        << "stray file " << entry.path().string();
  }
}

}  // namespace
}  // namespace clingfy::capture::background
