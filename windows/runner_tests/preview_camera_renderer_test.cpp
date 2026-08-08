#include "Preview/preview_camera_renderer.h"

#include <gtest/gtest.h>

namespace clingfy::preview {
namespace {

constexpr std::int64_t kThresh = kPreviewCameraSeekThresholdHns;  // 1s in hns

// --- cold start (no held frame yet) ---

TEST(PreviewCameraSeekTest, ColdStartNearZeroDoesNotSeek) {
  // Opening at/near the camera start: decode from the file start (cheap), no seek.
  EXPECT_FALSE(PreviewCameraShouldSeek(0, -1, false));
  EXPECT_FALSE(PreviewCameraShouldSeek(kThresh, -1, false));
}

TEST(PreviewCameraSeekTest, ColdStartFarInSeeks) {
  // Opening the preview already scrubbed deep into the clip → seek.
  EXPECT_TRUE(PreviewCameraShouldSeek(kThresh + 1, -1, false));
  EXPECT_TRUE(PreviewCameraShouldSeek(60'000'000, -1, false));  // 6s in
}

// --- normal playback (held frame present) ---

TEST(PreviewCameraSeekTest, SmallForwardStepPullsForward) {
  // 33 ms (one ~30fps frame) ahead of the held frame → pull, don't seek.
  EXPECT_FALSE(PreviewCameraShouldSeek(330'000 + 100'000, 100'000, true));
}

TEST(PreviewCameraSeekTest, BackwardJumpSeeks) {
  // Any backward move (scrub left) → seek; can't rewind a forward-only reader.
  EXPECT_TRUE(PreviewCameraShouldSeek(50'000, 5'000'000, true));
}

TEST(PreviewCameraSeekTest, LargeForwardJumpSeeks) {
  // Scrub forward beyond the threshold → seek instead of decoding every frame.
  EXPECT_TRUE(PreviewCameraShouldSeek(5'000'000 + kThresh + 1, 5'000'000, true));
}

TEST(PreviewCameraSeekTest, ForwardJustUnderThresholdPullsForward) {
  EXPECT_FALSE(
      PreviewCameraShouldSeek(5'000'000 + kThresh, 5'000'000, true));
}

// --- effect scale: export-canvas lengths resolved onto the preview texture ---

TEST(PreviewCameraEffectScaleTest, IsTheShortSideRatio) {
  // youtube169 @ p2160: export 3840x2160, preview texture 1280x720.
  EXPECT_NEAR(PreviewCameraEffectScale(720.0, 2160.0), 1.0 / 3.0, 1e-12);
  // reel916 @ p1080: export 1080x1920 (short 1080), preview 404x720 (short 404).
  EXPECT_NEAR(PreviewCameraEffectScale(404.0, 1080.0), 404.0 / 1080.0, 1e-12);
  // Same surface as the export => identity, which is what the export path gets.
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(2160.0, 2160.0), 1.0);
}

TEST(PreviewCameraEffectScaleTest, UnknownReferenceFallsBackToIdentityNotZero) {
  // The export size is unknown until the first decoded frame. Falling back to 0
  // would erase the border and collapse the shadow for those frames; identity
  // reproduces the previous appearance until the real size lands. This is the
  // one place the camera scale deliberately differs from
  // core::NormalizeToShortSide, which soft-fails to 0.
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(720.0, 0.0), 1.0);
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(720.0, -2160.0), 1.0);
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(0.0, 2160.0), 1.0);
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(-1.0, 2160.0), 1.0);
}

TEST(PreviewCameraNeedsRebuildTest, ScaleOnlyChangeStillRebuilds) {
  // The regression this term exists for: the canvas is identical and nothing is
  // dirty, but the export size resolved a frame late. Without the scale term
  // the painter keeps its identity-scaled border for the whole session.
  EXPECT_TRUE(PreviewCameraNeedsRebuild(/*dirty=*/false, 1280, 720,
                                        /*effect_scale=*/1.0 / 3.0, 1280, 720,
                                        /*prepared_effect_scale=*/1.0));
}

TEST(PreviewCameraNeedsRebuildTest, SteadyStateDoesNotRebuild) {
  EXPECT_FALSE(PreviewCameraNeedsRebuild(false, 1280, 720, 1.0 / 3.0, 1280, 720,
                                         1.0 / 3.0));
}

TEST(PreviewCameraNeedsRebuildTest, DirtyOrCanvasChangeStillRebuilds) {
  EXPECT_TRUE(PreviewCameraNeedsRebuild(true, 1280, 720, 1.0, 1280, 720, 1.0));
  EXPECT_TRUE(PreviewCameraNeedsRebuild(false, 640, 720, 1.0, 1280, 720, 1.0));
  EXPECT_TRUE(PreviewCameraNeedsRebuild(false, 1280, 360, 1.0, 1280, 720, 1.0));
}

namespace {

PreviewCameraComposition StyledComposition() {
  PreviewCameraComposition c;
  c.visible = true;
  c.size_factor = 0.25;
  c.border_width = 4.0;
  c.has_border_color = true;
  c.border_argb = 0xFFFFFFFFu;
  c.shadow_preset = 2;
  c.layout_preset = "overlayBottomRight";
  return c;
}

}  // namespace

TEST(ResolvePreviewCameraPlanTest, CarriesTheScaleOntoTheStyle) {
  // If this stops being set, the painter silently reverts to export-sized
  // border and shadow on a third-size texture.
  const auto plan =
      ResolvePreviewCameraPlan(StyledComposition(), 1280.0, 720.0, 1.0 / 3.0);
  EXPECT_NEAR(plan.style.effect_scale, 1.0 / 3.0, 1e-12);
  // The authored width is carried UNCHANGED; the painter applies the scale, so
  // one number stays the source of truth on all three surfaces.
  EXPECT_DOUBLE_EQ(plan.style.border_width, 4.0);
  EXPECT_EQ(plan.style.shadow_preset, 2);
}

TEST(ResolvePreviewCameraPlanTest, BorderIsProportionalToTheExportBubble) {
  // The headline property: the same authored border covers the same fraction of
  // the bubble on both surfaces. Fails today without the scale (3.09% vs 1.03%).
  const auto comp = StyledComposition();
  const auto preview =
      ResolvePreviewCameraPlan(comp, 1280.0, 720.0, 720.0 / 2160.0);
  const auto exported = ResolvePreviewCameraPlan(comp, 3840.0, 2160.0, 1.0);

  const double preview_px =
      preview.style.border_width * preview.style.effect_scale;
  const double export_px =
      exported.style.border_width * exported.style.effect_scale;
  EXPECT_NEAR(preview_px / preview.bubble.width,
              export_px / exported.bubble.width, 1e-9);
}

TEST(ResolvePreviewCameraPlanTest, FlooredBubbleMatchesTheExportProportion) {
  // reel916 portrait at the default size factor — the case where the 96px floor
  // binds on the preview and not on the export.
  // NB: not `small` — rpcndr.h #defines that to `char`.
  auto tiny = StyledComposition();
  tiny.size_factor = 0.18;
  const auto preview =
      ResolvePreviewCameraPlan(tiny, 404.0, 720.0, 404.0 / 1080.0);
  const auto exported = ResolvePreviewCameraPlan(tiny, 1080.0, 1920.0, 1.0);
  EXPECT_NEAR(preview.bubble.width / 404.0, exported.bubble.width / 1080.0,
              1e-9);
}

TEST(ResolvePreviewCameraPlanTest, IdentityScaleMatchesTheExportPlanExactly) {
  // Pins the export no-op through the same helper the preview uses.
  const auto comp = StyledComposition();
  const auto plan = ResolvePreviewCameraPlan(comp, 3840.0, 2160.0, 1.0);
  const auto expected = clingfy::capture::ComputeCameraBubbleRect(
      3840.0, 2160.0, comp.has_center, comp.center_x, comp.center_y,
      comp.layout_preset, comp.size_factor);
  EXPECT_DOUBLE_EQ(plan.bubble.x, expected.x);
  EXPECT_DOUBLE_EQ(plan.bubble.y, expected.y);
  EXPECT_DOUBLE_EQ(plan.bubble.width, expected.width);
  EXPECT_DOUBLE_EQ(plan.style.effect_scale, 1.0);
}

TEST(ResolvePreviewCameraPlanTest, NonPositiveScaleDegradesToIdentity) {
  const auto comp = StyledComposition();
  const auto plan = ResolvePreviewCameraPlan(comp, 1280.0, 720.0, 0.0);
  EXPECT_DOUBLE_EQ(plan.style.effect_scale, 1.0);
  EXPECT_DOUBLE_EQ(plan.bubble.width,
                   ResolvePreviewCameraPlan(comp, 1280.0, 720.0, 1.0)
                       .bubble.width);
}

}  // namespace
}  // namespace clingfy::preview
