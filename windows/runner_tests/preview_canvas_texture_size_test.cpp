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

// ---------------------------------------------------------------------------
// DecideCanvasAspectRebuild — when a canvas push must rebuild the session.
//
// A registered shared texture cannot be resized, so a layout switch only
// reshapes the preview via close+reopen. These tests pin the two properties
// that keep that from becoming an infinite close/reopen cycle.
// ---------------------------------------------------------------------------

// THE LOOP GUARD. Before the first frame the source dims are 0, and sizing from
// 0 yields the 1280x720 default — which mismatches any portrait texture. Were
// this to return true, the rebuild would push the canvas again, still with no
// decoded frame, and ask for another rebuild forever.
TEST(CanvasAspectRebuildTest, UnknownSourceDimensionsNeverRebuild) {
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(0, 0, 720, 1280,
                                                        "reel916", "p1080"));
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(-1, 1080, 720, 1280,
                                                        "reel916", "p1080"));
}

// No session open yet — nothing to compare against, so nothing to rebuild.
TEST(CanvasAspectRebuildTest, UnknownTextureSizeNeverRebuilds) {
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(kSrcW, kSrcH, 0, 0,
                                                        "reel916", "p1080"));
}

// THE TERMINATION PROPERTY. The rebuild re-pushes the canvas; that second push
// arrives with the texture already at the required size and MUST be a no-op.
TEST(CanvasAspectRebuildTest, MatchingTextureDoesNotRebuild) {
  const TextureSize required =
      PreviewEngine::ComputeCanvasTextureSize(kSrcW, kSrcH, "reel916", "p1080");
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(
      kSrcW, kSrcH, required.width, required.height, "reel916", "p1080"));
}

// The feature itself: a 16:9 recording moved into a 9:16 canvas needs a
// differently shaped texture, which is exactly the case the preview used to
// get wrong (it stayed 16:9 while the export went portrait).
TEST(CanvasAspectRebuildTest, LandscapeToPortraitLayoutRebuilds) {
  const TextureSize landscape =
      PreviewEngine::ComputeCanvasTextureSize(kSrcW, kSrcH, "youtube169", "p1080");
  EXPECT_TRUE(PreviewEngine::DecideCanvasAspectRebuild(
      kSrcW, kSrcH, landscape.width, landscape.height, "reel916", "p1080"));
}

// A resolution change is NOT a reshape: the texture is aspect-only inside a
// fixed budget, so 1080p -> 4K/8K moves the export target and nothing on screen.
// Rebuilding here would close and reopen the preview for no visible reason.
TEST(CanvasAspectRebuildTest, ResolutionOnlyChangeDoesNotRebuild) {
  const TextureSize at1080 =
      PreviewEngine::ComputeCanvasTextureSize(kSrcW, kSrcH, "youtube169", "p1080");
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(
      kSrcW, kSrcH, at1080.width, at1080.height, "youtube169", "p2160"));
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(
      kSrcW, kSrcH, at1080.width, at1080.height, "youtube169", "p4320"));
}

// Empty presets mean "Dart has not pushed canvas state yet", which sizes by the
// video aspect. A session opened that way must not immediately rebuild.
TEST(CanvasAspectRebuildTest, EmptyPresetsDoNotRebuildAVideoSizedTexture) {
  const TextureSize legacy =
      PreviewEngine::ComputePreviewTextureSize(kSrcW, kSrcH);
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(
      kSrcW, kSrcH, legacy.width, legacy.height, "", ""));
}

// One rebuild settles it: after reopening at the required size, deciding again
// with the same presets is false. Together with MatchingTextureDoesNotRebuild
// this is the full close/reopen cycle, executed twice.
TEST(CanvasAspectRebuildTest, RebuildIsIdempotentAfterTheReopen) {
  const TextureSize before =
      PreviewEngine::ComputeCanvasTextureSize(kSrcW, kSrcH, "youtube169", "p1080");
  ASSERT_TRUE(PreviewEngine::DecideCanvasAspectRebuild(
      kSrcW, kSrcH, before.width, before.height, "square11", "p1080"));

  // The reopen sizes the texture to what the new presets require.
  const TextureSize after = PreviewEngine::ComputeCanvasTextureSize(
      kSrcW, kSrcH, "square11", "p1080");
  EXPECT_FALSE(PreviewEngine::DecideCanvasAspectRebuild(
      kSrcW, kSrcH, after.width, after.height, "square11", "p1080"));
}

}  // namespace
}  // namespace clingfy::preview
