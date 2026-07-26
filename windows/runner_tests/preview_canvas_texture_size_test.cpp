#include <gtest/gtest.h>

#include <cmath>
#include <string>

#include "preview/preview_engine.h"

namespace clingfy::preview {
namespace {

using TextureSize = PreviewEngine::TextureSize;

double AspectOf(const TextureSize& s) {
  return static_cast<double>(s.width) / static_cast<double>(s.height);
}

// A 1920x1080 recording — the common case — inside each canvas preset.
constexpr int kSrcW = 1920;
constexpr int kSrcH = 1080;

// The regression this exists for. The texture used to be sized to the VIDEO
// aspect, so a 16:9 recording in a 9:16 reel canvas previewed as 16:9: switching
// the layout preset changed nothing on screen while the export changed
// completely. Verified on-device before this fix — the preview stayed wide.
TEST(CanvasTextureSizeTest, ReelCanvasProducesAPortraitTextureNotTheVideoAspect) {
  const TextureSize reel = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "reel916", "p1440");

  EXPECT_LT(AspectOf(reel), 1.0) << "9:16 canvas must yield a PORTRAIT texture";
  EXPECT_NEAR(AspectOf(reel), 9.0 / 16.0, 0.02);

  // And it must differ from the old video-aspect answer, or nothing changed.
  const TextureSize video_aspect =
      PreviewEngine::ComputePreviewTextureSize(kSrcW, kSrcH);
  EXPECT_GT(AspectOf(video_aspect), 1.0);
  EXPECT_NE(reel.width, video_aspect.width);
}

TEST(CanvasTextureSizeTest, SquareCanvasProducesASquareTexture) {
  const TextureSize s = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "square11", "p1440");
  EXPECT_NEAR(AspectOf(s), 1.0, 0.02);
}

TEST(CanvasTextureSizeTest, ClassicCanvasProducesFourThree) {
  const TextureSize s = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "classic43", "p1440");
  EXPECT_NEAR(AspectOf(s), 4.0 / 3.0, 0.02);
}

TEST(CanvasTextureSizeTest, WideCanvasMatchesAWideRecording) {
  const TextureSize s = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "youtube169", "p1440");
  EXPECT_NEAR(AspectOf(s), 16.0 / 9.0, 0.02);
}

// The export resolution must NOT change the texture size: the preview stays
// inside its budget and the canvas contract carries padding/radius as fractions.
// If this ever fails, a 4K export would allocate a 4K preview texture.
TEST(CanvasTextureSizeTest, ExportResolutionDoesNotChangeTheTextureSize) {
  const TextureSize at1440 = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "reel916", "p1440");
  const TextureSize at2160 = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "reel916", "p2160");
  const TextureSize at1080 = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "reel916", "p1080");
  EXPECT_EQ(at1440.width, at2160.width);
  EXPECT_EQ(at1440.height, at2160.height);
  EXPECT_EQ(at1440.width, at1080.width);
  EXPECT_EQ(at1440.height, at1080.height);
}

// Stays inside the historical budget on every preset, so this cannot regress
// memory or the shared-handle path.
TEST(CanvasTextureSizeTest, EveryPresetStaysInsideTheBudget) {
  for (const std::string layout :
       {"auto", "classic43", "square11", "youtube169", "reel916"}) {
    const TextureSize s =
        PreviewEngine::ComputeCanvasTextureSize(kSrcW, kSrcH, layout, "p1440");
    EXPECT_GT(s.width, 0) << layout;
    EXPECT_GT(s.height, 0) << layout;
    EXPECT_LE(s.width, 1280) << layout;
    EXPECT_LE(s.height, 720) << layout;
    // Even-aligned, same rule the video-aspect sizing always applied.
    EXPECT_EQ(s.width % 2, 0) << layout;
    EXPECT_EQ(s.height % 2, 0) << layout;
  }
}

// Before Dart has pushed any canvas state the presets are empty. That must be a
// no-op — identical to the old behaviour — so previewOpen is unchanged until
// the presets are actually known.
TEST(CanvasTextureSizeTest, EmptyPresetsFallBackToTheVideoAspect) {
  const TextureSize fallback =
      PreviewEngine::ComputeCanvasTextureSize(kSrcW, kSrcH, "", "");
  const TextureSize legacy =
      PreviewEngine::ComputePreviewTextureSize(kSrcW, kSrcH);
  EXPECT_EQ(fallback.width, legacy.width);
  EXPECT_EQ(fallback.height, legacy.height);
}

TEST(CanvasTextureSizeTest, DegenerateSourceKeepsTheBudget) {
  const TextureSize zero =
      PreviewEngine::ComputeCanvasTextureSize(0, 0, "reel916", "p1440");
  EXPECT_EQ(zero.width, 1280);
  EXPECT_EQ(zero.height, 720);

  const TextureSize negative =
      PreviewEngine::ComputeCanvasTextureSize(-1, 1080, "reel916", "p1440");
  EXPECT_EQ(negative.width, 1280);
  EXPECT_EQ(negative.height, 720);
}

// An unrecognized preset must not produce a degenerate texture — ResolveTargetSize
// falls through to its auto branch, and we must still get something drawable.
TEST(CanvasTextureSizeTest, UnknownPresetStillProducesADrawableTexture) {
  const TextureSize s = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "not_a_real_preset", "also_fake");
  EXPECT_GT(s.width, 0);
  EXPECT_GT(s.height, 0);
  EXPECT_LE(s.width, 1280);
  EXPECT_LE(s.height, 720);
}

}  // namespace
}  // namespace clingfy::preview
