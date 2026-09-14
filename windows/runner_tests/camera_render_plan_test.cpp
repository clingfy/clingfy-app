#include "Capture/Camera/camera_render_plan.h"

#include <gtest/gtest.h>

// Headless by construction: camera_render_plan.h is D2D-free, so every property
// below is asserted without a device. That is the whole point of the layer —
// the wiring bugs these tests catch used to be reachable only through the pixel
// test, which needs a GPU.
namespace clingfy::capture {
namespace {

// The migrated fixture from ResolvePreviewCameraPlanTest: a composition with a
// border and a shadow, so the style terms are observable.
CameraRenderSpec StyledSpec() {
  CameraRenderSpec s;
  s.visible = true;
  s.size_factor = 0.25;
  s.border_width = 4.0;
  s.has_border_color = true;
  s.border_argb = 0xFFFFFFFFu;
  s.shadow_preset = 2;
  s.layout_preset = "overlayBottomRight";
  return s;
}

// --- the five properties migrated from preview_camera_renderer_test.cpp ------
// These pin the effect_scale correction that PR #485 made load-bearing. They
// moved here BEFORE the preview leg switches over, so no commit exists where
// the proportionality guard is missing.

TEST(BuildCameraRenderPlanTest, CarriesTheScaleOntoTheStyle) {
  // If this stops being set, the painter silently reverts to export-sized
  // border and shadow on a third-size texture.
  const auto plan =
      BuildCameraRenderPlan(StyledSpec(), 1280.0, 720.0, 1.0 / 3.0);
  EXPECT_NEAR(plan.style.effect_scale, 1.0 / 3.0, 1e-12);
  // The authored width is carried UNCHANGED; the painter applies the scale, so
  // one number stays the source of truth on all three surfaces.
  EXPECT_DOUBLE_EQ(plan.style.border_width, 4.0);
  EXPECT_EQ(plan.style.shadow_preset, 2);
}

TEST(BuildCameraRenderPlanTest, BorderIsProportionalToTheExportBubble) {
  // The headline property: the same authored border covers the same fraction of
  // the bubble on both surfaces. Fails without the scale (3.09% vs 1.03%).
  const auto spec = StyledSpec();
  const auto preview =
      BuildCameraRenderPlan(spec, 1280.0, 720.0, 720.0 / 2160.0);
  const auto exported = BuildCameraRenderPlan(spec, 3840.0, 2160.0, 1.0);

  const double preview_px =
      preview.style.border_width * preview.style.effect_scale;
  const double export_px =
      exported.style.border_width * exported.style.effect_scale;
  EXPECT_NEAR(preview_px / preview.bubble.width,
              export_px / exported.bubble.width, 1e-9);
}

TEST(BuildCameraRenderPlanTest, FlooredBubbleMatchesTheExportProportion) {
  // reel916 portrait at the default size factor — the case where the 96px floor
  // binds on the preview and not on the export.
  // NB: not `small` — rpcndr.h #defines that to `char`.
  auto tiny = StyledSpec();
  tiny.size_factor = 0.18;
  const auto preview = BuildCameraRenderPlan(tiny, 404.0, 720.0, 404.0 / 1080.0);
  const auto exported = BuildCameraRenderPlan(tiny, 1080.0, 1920.0, 1.0);
  EXPECT_NEAR(preview.bubble.width / 404.0, exported.bubble.width / 1080.0,
              1e-9);
}

TEST(BuildCameraRenderPlanTest, IdentityScaleMatchesTheExportPlanExactly) {
  const auto spec = StyledSpec();
  const auto plan = BuildCameraRenderPlan(spec, 3840.0, 2160.0, 1.0);
  const auto expected = ComputeCameraBubbleRect(
      3840.0, 2160.0, spec.has_center, spec.center_x, spec.center_y,
      spec.layout_preset, spec.size_factor);
  EXPECT_DOUBLE_EQ(plan.bubble.x, expected.x);
  EXPECT_DOUBLE_EQ(plan.bubble.y, expected.y);
  EXPECT_DOUBLE_EQ(plan.bubble.width, expected.width);
  EXPECT_DOUBLE_EQ(plan.style.effect_scale, 1.0);
}

TEST(BuildCameraRenderPlanTest, NonPositiveScaleDegradesToIdentity) {
  const auto spec = StyledSpec();
  const auto plan = BuildCameraRenderPlan(spec, 1280.0, 720.0, 0.0);
  EXPECT_DOUBLE_EQ(plan.style.effect_scale, 1.0);
  EXPECT_DOUBLE_EQ(plan.bubble.width,
                   BuildCameraRenderPlan(spec, 1280.0, 720.0, 1.0).bubble.width);
}

// --- what the shared builder adds over the preview-only one ------------------

TEST(BuildCameraRenderPlanTest, PlanAssignsEveryStyleField) {
  // Every field non-default, so an unassigned one shows up as the painter
  // table's value rather than the spec's. chroma_strength dodges BOTH tables
  // (0.0 painter, 0.4 wire) so neither can pass by accident.
  CameraRenderSpec spec;
  spec.mirror = true;
  spec.opacity = 0.63;
  spec.border_width = 7.5;
  spec.has_border_color = true;
  spec.border_argb = 0xFF3366CCu;
  spec.shadow_preset = 3;
  spec.chroma_enabled = true;
  spec.chroma_strength = 0.77;
  spec.has_chroma_color = true;
  spec.chroma_argb = 0xFF00FF00u;

  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 0.5);

  // A structured binding, not eleven field reads: adding a 12th field to
  // CameraBubbleStyle fails to COMPILE here until the builder maps it. That is
  // the guard — the assertions below are only the payload.
  const auto& [mirror, opacity, border_width, has_border_color, border_argb,
               shadow_preset, effect_scale, chroma_enabled, chroma_strength,
               has_chroma_color, chroma_argb] = plan.style;
  EXPECT_TRUE(mirror);
  EXPECT_DOUBLE_EQ(opacity, 0.63);
  EXPECT_DOUBLE_EQ(border_width, 7.5);
  EXPECT_TRUE(has_border_color);
  EXPECT_EQ(border_argb, 0xFF3366CCu);
  EXPECT_EQ(shadow_preset, 3);
  EXPECT_DOUBLE_EQ(effect_scale, 0.5);
  EXPECT_TRUE(chroma_enabled);
  EXPECT_DOUBLE_EQ(chroma_strength, 0.77);
  EXPECT_TRUE(has_chroma_color);
  EXPECT_EQ(chroma_argb, 0xFF00FF00u);

  // The three painter arguments that used to bypass the plan entirely.
  spec.shape = "hexagon";
  spec.corner_radius = 18.0;
  spec.content_mode = "contain";
  const auto shaped = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 0.5);
  EXPECT_EQ(shaped.shape, "hexagon");
  EXPECT_DOUBLE_EQ(shaped.corner_radius, 18.0);
  EXPECT_EQ(shaped.content_mode, "contain");
}

TEST(BuildCameraRenderPlanTest, DefaultSpecResolvesToTheWireDefaults) {
  // The two default tables DISAGREE on chroma_strength (0.4 wire, 0.0 painter).
  // The spec's table must win, because the builder assigns every field — if a
  // future edit drops an assignment, this is where the painter's table leaks
  // back in.
  const auto plan = BuildCameraRenderPlan(CameraRenderSpec{}, 1920.0, 1080.0,
                                          kExportCameraEffectScale);
  EXPECT_DOUBLE_EQ(plan.style.chroma_strength, 0.4);
  EXPECT_FALSE(plan.style.chroma_enabled);
  EXPECT_DOUBLE_EQ(plan.style.opacity, 1.0);
  EXPECT_DOUBLE_EQ(plan.style.border_width, 0.0);
  EXPECT_DOUBLE_EQ(plan.style.effect_scale, 1.0);
}

TEST(BuildCameraRenderPlanTest, ExportScaleIsIdentityAndEqualsTheLegacyRect) {
  // The export used to call ComputeCameraBubbleRect with SEVEN arguments,
  // taking the defaulted floor. The builder always passes the eighth. This
  // makes that default→explicit transition behaviour-neutral BY TEST rather
  // than by argument.
  const auto spec = StyledSpec();
  const auto plan =
      BuildCameraRenderPlan(spec, 3840.0, 2160.0, kExportCameraEffectScale);
  const auto legacy = ComputeCameraBubbleRect(
      3840.0, 2160.0, spec.has_center, spec.center_x, spec.center_y,
      spec.layout_preset, spec.size_factor);
  EXPECT_DOUBLE_EQ(plan.bubble.x, legacy.x);
  EXPECT_DOUBLE_EQ(plan.bubble.y, legacy.y);
  EXPECT_DOUBLE_EQ(plan.bubble.width, legacy.width);
  EXPECT_DOUBLE_EQ(plan.bubble.height, legacy.height);
  EXPECT_DOUBLE_EQ(kExportCameraEffectScale, 1.0);
}

TEST(BuildCameraRenderPlanTest, ANonIdentityScaleIsWhatDistinguishesTheLegs) {
  // Without this the assertion above is uninformative: it would also pass if
  // the floor argument were ignored outright. A portrait preview surface at the
  // default size factor is exactly where the 96px floor binds at scale 1.0 and
  // does not at 1/3.
  auto spec = StyledSpec();
  spec.size_factor = 0.18;
  const auto legacy = ComputeCameraBubbleRect(
      404.0, 720.0, spec.has_center, spec.center_x, spec.center_y,
      spec.layout_preset, spec.size_factor);
  const auto scaled = BuildCameraRenderPlan(spec, 404.0, 720.0, 1.0 / 3.0);
  EXPECT_DOUBLE_EQ(legacy.width, kCameraBubbleMinSidePx);  // the floor binds
  EXPECT_LT(scaled.bubble.width, legacy.width);            // and is resolved away
}

TEST(BuildCameraRenderPlanTest,
     AnimInvariantsAreParsedOnceAndCarryNoPerFrameFields) {
  auto spec = StyledSpec();
  spec.intro_preset = "pop";
  spec.outro_preset = "shrink";
  spec.intro_duration_ms = 420;
  spec.outro_duration_ms = 360;
  spec.zoom_emphasis_preset = "pulse";
  spec.zoom_emphasis_strength = 0.15;

  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0);

  // SIX, and only six. A structured binding again, so the day someone tries to
  // park zoom_scale / zoom_in_segment / zoom_local_seconds in here — the
  // never-pulsing-bubble footgun CameraExportRenderer::Draw forbids — this
  // stops compiling instead of silently defaulting them.
  const auto& [intro, outro, intro_ms, outro_ms, emphasis, strength] = plan.anim;
  EXPECT_EQ(intro, CameraIntroKind::kPop);
  EXPECT_EQ(outro, CameraOutroKind::kShrink);
  EXPECT_EQ(intro_ms, 420);
  EXPECT_EQ(outro_ms, 360);
  EXPECT_EQ(emphasis, CameraZoomEmphasisKind::kPulse);
  EXPECT_DOUBLE_EQ(strength, 0.15);
}

TEST(BuildCameraRenderPlanTest, UnknownPresetsSoftFailToNone) {
  auto spec = StyledSpec();
  spec.intro_preset = "teleport";
  spec.outro_preset = "";
  spec.zoom_emphasis_preset = "strobe";
  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0);
  EXPECT_EQ(plan.anim.intro, CameraIntroKind::kNone);
  EXPECT_EQ(plan.anim.outro, CameraOutroKind::kNone);
  EXPECT_EQ(plan.anim.emphasis, CameraZoomEmphasisKind::kNone);
}

TEST(BuildCameraRenderPlanTest, SlideEdgeComesFromTheComputedBubbleNotTheRawCenter) {
  // center_y is y-UP on the wire (0 = canvas BOTTOM) and ComputeCameraBubbleRect
  // flips it into D2D's y-DOWN space. Resolving the edge from the RAW value
  // instead double-flips it and slides the bubble out of the opposite edge —
  // a defect no static assertion catches, because both answers are valid enums.
  //
  // 0.9 y-UP means "near the TOP of the canvas". Raw and flipped land on
  // opposite halves, so the wrong source fails loudly as kBottom.
  auto spec = StyledSpec();
  spec.has_center = true;
  spec.center_x = 0.5;
  spec.center_y = 0.9;
  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0);
  EXPECT_EQ(plan.slide_edge, CameraSlideEdge::kTop);

  // The mirror image, so neither answer can be a constant.
  spec.center_y = 0.1;
  EXPECT_EQ(BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0).slide_edge,
            CameraSlideEdge::kBottom);
}

TEST(BuildCameraRenderPlanTest, CarriesTheZoomTrioAndTheCanvas) {
  // The exact omission that would silently kill scale-with-screen-zoom on the
  // export: ResolveCameraZoomScale returns a fixed 1.0 for an EMPTY behaviour,
  // so dropping these three from the plan produces a bubble that simply never
  // grows — no error, no warning, no failing pixel.
  auto spec = StyledSpec();
  spec.zoom_behavior = "scaleWithScreenZoom";
  spec.zoom_scale_multiplier = 0.35;
  spec.layout_preset = "overlayTopLeft";

  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0);
  EXPECT_EQ(plan.zoom_behavior, "scaleWithScreenZoom");
  EXPECT_DOUBLE_EQ(plan.zoom_scale_multiplier, 0.35);
  EXPECT_EQ(plan.layout_preset, "overlayTopLeft");
  // The canvas travels with the plan because ResolveCameraAnimation needs it
  // per frame for the post-scale clamp and the offscreen slide offset.
  EXPECT_DOUBLE_EQ(plan.canvas_w, 1920.0);
  EXPECT_DOUBLE_EQ(plan.canvas_h, 1080.0);
}

// --- the per-frame half ------------------------------------------------------

TEST(ResolveCameraRenderFrameTest, ComposesTheZoomScaleAndThePulse) {
  // Proves the nine-line dedupe is equivalent to what both Draw bodies did by
  // hand: resolve the zoom scale, drop it into the params, then animate.
  auto spec = StyledSpec();
  spec.zoom_behavior = "scaleWithScreenZoom";
  spec.zoom_scale_multiplier = 0.35;
  spec.zoom_emphasis_preset = "pulse";
  spec.zoom_emphasis_strength = 0.15;
  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0);

  const auto got = ResolveCameraRenderFrame(plan, /*frame_ms=*/5000,
                                            /*total_duration_ms=*/10000,
                                            /*screen_zoom=*/2.0,
                                            /*zoom_in_segment=*/true,
                                            /*zoom_segment_local_ms=*/250);

  CameraAnimationParams params;
  params.intro = plan.anim.intro;
  params.outro = plan.anim.outro;
  params.intro_duration_ms = plan.anim.intro_duration_ms;
  params.outro_duration_ms = plan.anim.outro_duration_ms;
  params.emphasis = plan.anim.emphasis;
  params.emphasis_strength = plan.anim.emphasis_strength;
  params.zoom_scale = ResolveCameraZoomScale(spec.zoom_behavior,
                                             spec.zoom_scale_multiplier, 2.0,
                                             spec.layout_preset);
  params.zoom_in_segment = true;
  params.zoom_local_seconds = 0.25;
  const auto expected = ResolveCameraAnimation(params, 5000, 10000, plan.bubble,
                                               1920.0, 1080.0, plan.slide_edge);

  EXPECT_DOUBLE_EQ(got.scale, expected.scale);
  EXPECT_DOUBLE_EQ(got.opacity, expected.opacity);
  EXPECT_DOUBLE_EQ(got.translate_x, expected.translate_x);
  EXPECT_DOUBLE_EQ(got.translate_y, expected.translate_y);
  // And it is not the identity, or the equality above would prove nothing:
  // 1.35 from the zoom excess, times the pulse at half a cycle.
  EXPECT_GT(got.scale, 1.35);
}

TEST(ResolveCameraRenderFrameTest, NegativeSegmentClockReadsAsZero) {
  // The clamp both Draw bodies carried inline. A negative local clock would
  // drive cos() backwards through the throb rather than resting at 1.0.
  auto spec = StyledSpec();
  spec.zoom_emphasis_preset = "pulse";
  spec.zoom_emphasis_strength = 0.15;
  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0);
  const auto negative =
      ResolveCameraRenderFrame(plan, 5000, 10000, 1.0, true, -400);
  const auto zero = ResolveCameraRenderFrame(plan, 5000, 10000, 1.0, true, 0);
  EXPECT_DOUBLE_EQ(negative.scale, zero.scale);
}

TEST(ResolveCameraRenderFrameTest, TwoCallsWithDifferentZoomStateDoNotLeakIntoEachOther) {
  // The const-plan property that replaces the preview's in-place mutation of a
  // cached anim_params_ member. Under the old shape the per-frame fields lived
  // on the renderer; here they cannot outlive the call.
  auto spec = StyledSpec();
  spec.zoom_emphasis_preset = "pulse";
  spec.zoom_emphasis_strength = 0.15;
  const auto plan = BuildCameraRenderPlan(spec, 1920.0, 1080.0, 1.0);

  const auto in_segment =
      ResolveCameraRenderFrame(plan, 5000, 10000, 1.0, true, 250);
  const auto out_of_segment =
      ResolveCameraRenderFrame(plan, 5000, 10000, 1.0, false, 250);
  const auto in_segment_again =
      ResolveCameraRenderFrame(plan, 5000, 10000, 1.0, true, 250);

  EXPECT_GT(in_segment.scale, out_of_segment.scale);
  EXPECT_DOUBLE_EQ(out_of_segment.scale, 1.0);
  EXPECT_DOUBLE_EQ(in_segment_again.scale, in_segment.scale);
}

}  // namespace
}  // namespace clingfy::capture
