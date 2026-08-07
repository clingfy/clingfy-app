#include "Capture/Camera/camera_export_layout.h"

#include <gtest/gtest.h>

#include <vector>

namespace clingfy::capture {
namespace {

// 1920x1080 canvas, 18% size factor → side = min(1920,1080)*0.18 = 194.4px.
constexpr double kW = 1920.0;
constexpr double kH = 1080.0;

TEST(CameraExportLayoutTest, ManualCenterPlacesSquareBubble) {
  const CameraBubbleRect r =
      ComputeCameraBubbleRect(kW, kH, /*has_center=*/true, 0.5, 0.5, "", 0.18);
  EXPECT_DOUBLE_EQ(r.width, r.height);  // always square
  const double side = 1080.0 * 0.18;
  EXPECT_NEAR(r.width, side, 0.001);
  // Centered: x = 0.5*W - side/2.
  EXPECT_NEAR(r.x, kW / 2.0 - side / 2.0, 0.001);
  EXPECT_NEAR(r.y, kH / 2.0 - side / 2.0, 0.001);
}

TEST(CameraExportLayoutTest, ManualCenterYIsBottomUp) {
  // `cameraNormalizedCenter` is y-UP: Dart stores `1 - dy` and macOS consumes
  // it as a bottom-up CGRect, so a HIGH y means the TOP of the canvas. Every
  // pre-existing manual-center case here used a vertically symmetric center
  // (0.5 / clamped corners), which is exactly how a mirrored placement went
  // unnoticed — so assert the direction explicitly.
  const double side = kH * 0.18;
  const auto high = ComputeCameraBubbleRect(kW, kH, true, 0.5, 0.9, "", 0.18);
  const auto low = ComputeCameraBubbleRect(kW, kH, true, 0.5, 0.1, "", 0.18);
  EXPECT_NEAR(high.y, 0.1 * kH - side / 2.0, 0.001);
  EXPECT_NEAR(low.y, 0.9 * kH - side / 2.0, 0.001);
  EXPECT_LT(high.y, low.y);  // y-UP 0.9 sits ABOVE y-UP 0.1
}

TEST(CameraExportLayoutTest, PresetCentersAreNotFlipped) {
  // Presets are authored in y-DOWN space, so they must bypass the flip: a
  // top-left preset stays visually at the top.
  const auto tl =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayTopLeft", 0.18);
  const auto bl =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayBottomLeft", 0.18);
  EXPECT_LT(tl.y, kH / 2.0);
  EXPECT_GT(bl.y, kH / 2.0);
}

TEST(CameraExportLayoutTest, SizeFactorClampedToRange) {
  // Use a large canvas so the 0.08 floor stays well above the 96px min-side
  // floor (tested separately) and the factor clamp is what we observe.
  constexpr double big = 4000.0;
  EXPECT_NEAR(ComputeCameraBubbleRect(big, big, true, 0.5, 0.5, "", 0.01).width,
              big * 0.08, 0.001);
  EXPECT_NEAR(ComputeCameraBubbleRect(big, big, true, 0.5, 0.5, "", 0.99).width,
              big * 0.45, 0.001);
}

TEST(CameraExportLayoutTest, MinSideFloorApplies) {
  // Tiny canvas: 200x200 at 0.08 → 16px, floored to the 96px minimum.
  const CameraBubbleRect r =
      ComputeCameraBubbleRect(200.0, 200.0, true, 0.5, 0.5, "", 0.08);
  EXPECT_NEAR(r.width, kCameraBubbleMinSidePx, 0.001);
}

TEST(CameraExportLayoutTest, ClampsFullyOnCanvas) {
  // Center at the far corner would push the bubble off-canvas; it must clamp so
  // the whole square stays inside [0, W]x[0, H].
  const CameraBubbleRect r =
      ComputeCameraBubbleRect(kW, kH, true, 1.0, 1.0, "", 0.45);
  EXPECT_GE(r.x, 0.0);
  EXPECT_GE(r.y, 0.0);
  EXPECT_LE(r.x + r.width, kW + 0.001);
  EXPECT_LE(r.y + r.height, kH + 0.001);
}

TEST(CameraExportLayoutTest, PresetCornersDiffer) {
  const auto br = ComputeCameraBubbleRect(kW, kH, false, 0, 0,
                                          "overlayBottomRight", 0.18);
  const auto tl =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayTopLeft", 0.18);
  const auto tr =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayTopRight", 0.18);
  const auto bl =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "overlayBottomLeft", 0.18);
  // Bottom-right is to the right of + below top-left.
  EXPECT_GT(br.x, tl.x);
  EXPECT_GT(br.y, tl.y);
  // Top-right shares br's x-side but tl's y-side.
  EXPECT_NEAR(tr.x, br.x, 0.001);
  EXPECT_NEAR(tr.y, tl.y, 0.001);
  EXPECT_NEAR(bl.x, tl.x, 0.001);
  EXPECT_NEAR(bl.y, br.y, 0.001);
}

TEST(CameraExportLayoutTest, UnknownPresetFallsBackToBottomRight) {
  const auto unknown =
      ComputeCameraBubbleRect(kW, kH, false, 0, 0, "sideBySideLeft", 0.18);
  const auto br = ComputeCameraBubbleRect(kW, kH, false, 0, 0,
                                          "overlayBottomRight", 0.18);
  EXPECT_NEAR(unknown.x, br.x, 0.001);
  EXPECT_NEAR(unknown.y, br.y, 0.001);
}

TEST(CameraExportLayoutTest, DegenerateCanvasIsEmpty) {
  const auto r = ComputeCameraBubbleRect(0.0, 0.0, true, 0.5, 0.5, "", 0.18);
  EXPECT_DOUBLE_EQ(r.width, 0.0);
  EXPECT_DOUBLE_EQ(r.height, 0.0);
}

// --- time alignment ---------------------------------------------------------

TEST(CameraExportSyncTest, CameraTimeSubtractsStartOffset) {
  EXPECT_EQ(CameraTimeMsForFrame(1000, 150), 850);
  EXPECT_EQ(CameraTimeMsForFrame(150, 150), 0);
  EXPECT_EQ(CameraTimeMsForFrame(100, 150), -50);  // before camera start
}

TEST(CameraExportSyncTest, HeldFrameSelection) {
  const std::vector<std::int64_t> frames = {0, 33, 66, 100, 133};
  EXPECT_EQ(SelectHeldCameraFrameIndex(-1, frames), -1);   // negative time
  EXPECT_EQ(SelectHeldCameraFrameIndex(0, frames), 0);     // exactly first
  EXPECT_EQ(SelectHeldCameraFrameIndex(50, frames), 1);    // hold 33
  EXPECT_EQ(SelectHeldCameraFrameIndex(66, frames), 2);    // exactly third
  EXPECT_EQ(SelectHeldCameraFrameIndex(9999, frames), 4);  // hold last
}

TEST(CameraExportSyncTest, BeforeFirstFrameHoldsNothing) {
  const std::vector<std::int64_t> frames = {200, 233, 266};
  // camera_ms past start (>=0) but before the first recorded frame → nothing.
  EXPECT_EQ(SelectHeldCameraFrameIndex(100, frames), -1);
}

TEST(CameraExportSyncTest, AlignmentAcrossPauseGapHolds) {
  // Pause-aware timestamps: a gap in recorded camera frames (paused region).
  // After resume the alignment still picks the latest frame <= camera time.
  const std::vector<std::int64_t> frames = {0, 33, 66, /*resume*/ 500, 533};
  EXPECT_EQ(SelectHeldCameraFrameIndex(100, frames), 2);   // held through pause
  EXPECT_EQ(SelectHeldCameraFrameIndex(499, frames), 2);   // still held at gap
  EXPECT_EQ(SelectHeldCameraFrameIndex(500, frames), 3);   // resume frame
}

// --- shadow style (Phase 9.5) -----------------------------------------------

TEST(CameraShadowStyleTest, PresetZeroAndUnknownDisabled) {
  EXPECT_FALSE(ResolveCameraShadowStyle(0).enabled);
  EXPECT_FALSE(ResolveCameraShadowStyle(-1).enabled);
  EXPECT_FALSE(ResolveCameraShadowStyle(99).enabled);
}

TEST(CameraShadowStyleTest, PresetsMatchMacOsParityWithFlippedY) {
  // macOS uses a y-UP space (offset.height -2/-4/-6); D2D is y-DOWN so the
  // shadow drops with a POSITIVE y. Opacity/radius mirror macOS shadowStyle.
  const auto s1 = ResolveCameraShadowStyle(1);
  EXPECT_TRUE(s1.enabled);
  EXPECT_DOUBLE_EQ(s1.opacity, 0.18);
  EXPECT_DOUBLE_EQ(s1.blur_radius, 10.0);
  EXPECT_DOUBLE_EQ(s1.offset_x, 0.0);
  EXPECT_DOUBLE_EQ(s1.offset_y, 2.0);

  const auto s2 = ResolveCameraShadowStyle(2);
  EXPECT_DOUBLE_EQ(s2.opacity, 0.24);
  EXPECT_DOUBLE_EQ(s2.blur_radius, 16.0);
  EXPECT_DOUBLE_EQ(s2.offset_y, 4.0);

  const auto s3 = ResolveCameraShadowStyle(3);
  EXPECT_DOUBLE_EQ(s3.opacity, 0.32);
  EXPECT_DOUBLE_EQ(s3.blur_radius, 22.0);
  EXPECT_DOUBLE_EQ(s3.offset_y, 6.0);
}

TEST(CameraShadowStyleTest, StrongerPresetMeansMoreOpacityAndBlur) {
  const auto s1 = ResolveCameraShadowStyle(1);
  const auto s2 = ResolveCameraShadowStyle(2);
  const auto s3 = ResolveCameraShadowStyle(3);
  EXPECT_LT(s1.opacity, s2.opacity);
  EXPECT_LT(s2.opacity, s3.opacity);
  EXPECT_LT(s1.blur_radius, s2.blur_radius);
  EXPECT_LT(s2.blur_radius, s3.blur_radius);
}

TEST(CameraShadowStyleTest, DefaultScaleIsIdentity) {
  // Pins the export/live no-op: the new parameter must not have moved shipped
  // output for anyone who does not pass it.
  for (int preset = 0; preset <= 3; ++preset) {
    const auto implicit_arg = ResolveCameraShadowStyle(preset);
    const auto explicit_arg = ResolveCameraShadowStyle(preset, 1.0);
    EXPECT_EQ(implicit_arg.enabled, explicit_arg.enabled) << "preset " << preset;
    EXPECT_DOUBLE_EQ(implicit_arg.opacity, explicit_arg.opacity);
    EXPECT_DOUBLE_EQ(implicit_arg.blur_radius, explicit_arg.blur_radius);
    EXPECT_DOUBLE_EQ(implicit_arg.offset_x, explicit_arg.offset_x);
    EXPECT_DOUBLE_EQ(implicit_arg.offset_y, explicit_arg.offset_y);
  }
}

TEST(CameraShadowStyleTest, ScaleMultipliesLengthsButNotOpacity) {
  // blur radius and both offsets are lengths and live on the canvas; opacity is
  // dimensionless. Scaling opacity would make the preview's shadow fainter as
  // well as smaller, which is not what the export shows.
  const auto s = ResolveCameraShadowStyle(2, 1.0 / 3.0);
  EXPECT_TRUE(s.enabled);
  EXPECT_NEAR(s.blur_radius, 16.0 / 3.0, 1e-9);
  EXPECT_NEAR(s.offset_y, 4.0 / 3.0, 1e-9);
  EXPECT_NEAR(s.offset_x, 0.0, 1e-9);
  EXPECT_DOUBLE_EQ(s.opacity, 0.24);
}

TEST(CameraShadowStyleTest, ShadowIsProportionalAcrossCanvasSizes) {
  // The parity property itself, stated against the bubble the shadow hangs off.
  // (Local constants: the shared kPreview*/kExport* ones are declared further
  // down, next to the CameraParityTest block.)
  constexpr double kPvW = 1280.0;
  constexpr double kPvH = 720.0;
  constexpr double kExW = 3840.0;
  constexpr double kExH = 2160.0;
  const auto preview_bubble =
      ComputeCameraBubbleRect(kPvW, kPvH, false, 0, 0, "", 0.25);
  const auto export_bubble =
      ComputeCameraBubbleRect(kExW, kExH, false, 0, 0, "", 0.25);
  const auto preview_sh = ResolveCameraShadowStyle(3, kPvH / kExH);
  const auto export_sh = ResolveCameraShadowStyle(3);
  EXPECT_NEAR(preview_sh.blur_radius / preview_bubble.width,
              export_sh.blur_radius / export_bubble.width, 1e-9);
  EXPECT_NEAR(preview_sh.offset_y / preview_bubble.height,
              export_sh.offset_y / export_bubble.height, 1e-9);
}

TEST(CameraShadowStyleTest, NonPositiveScaleCollapsesGeometryNotOpacity) {
  // A not-yet-known reference must not produce a negative blur: the painter
  // sizes its bake bitmap with ceil(stddev*3) + border/2 + 2, which would go
  // negative and truncate to a zero-dimension bitmap.
  for (const double scale : {0.0, -2.0}) {
    const auto s = ResolveCameraShadowStyle(3, scale);
    EXPECT_DOUBLE_EQ(s.blur_radius, 0.0) << "scale " << scale;
    EXPECT_DOUBLE_EQ(s.offset_x, 0.0);
    EXPECT_DOUBLE_EQ(s.offset_y, 0.0);
    EXPECT_DOUBLE_EQ(s.opacity, 0.32);
  }
}

// --- intro/outro animation timeline (Phase 9.7) -----------------------------

namespace {
// A representative bottom-right bubble on a 1920x1080 canvas.
const CameraBubbleRect kBubble{/*x=*/1600.0, /*y=*/800.0, /*w=*/200.0,
                               /*h=*/200.0};
constexpr double kCanvasW = 1920.0;
constexpr double kCanvasH = 1080.0;
constexpr std::int64_t kTotalMs = 1000;

CameraAnimationParams MakeParams(CameraIntroKind intro, CameraOutroKind outro,
                                 int intro_ms = 200, int outro_ms = 200) {
  CameraAnimationParams p;
  p.intro = intro;
  p.outro = outro;
  p.intro_duration_ms = intro_ms;
  p.outro_duration_ms = outro_ms;
  return p;
}

CameraAnimationOutput Resolve(const CameraAnimationParams& p, std::int64_t t,
                              CameraSlideEdge edge = CameraSlideEdge::kRight) {
  return ResolveCameraAnimation(p, t, kTotalMs, kBubble, kCanvasW, kCanvasH,
                                edge);
}
}  // namespace

// --- preview vs export geometry parity --------------------------------------
//
// The inline preview composites into a texture capped near 1280x720 while the
// export renders at the user's resolution, so the two agree PROPORTIONALLY, not
// pixel for pixel. These assert the proportional contract and, just as
// importantly, PIN the two places it legitimately breaks — a parity test that
// quietly absorbed those with a fat epsilon would be worse than none.

namespace {
constexpr double kPreviewW = 1280.0;
constexpr double kPreviewH = 720.0;
constexpr double kExportW = 3840.0;
constexpr double kExportH = 2160.0;
}  // namespace

TEST(CameraParityTest, BubbleGeometryIsProportionalAcrossCanvasSizes) {
  // Same composition, two canvases: the bubble's normalized centre and its size
  // as a fraction of the short edge must match. This is the property that makes
  // the shared painter produce a WYSIWYG bubble on both surfaces.
  const auto preview = ComputeCameraBubbleRect(kPreviewW, kPreviewH, false, 0, 0,
                                               "overlayBottomRight", 0.25);
  const auto exported = ComputeCameraBubbleRect(kExportW, kExportH, false, 0, 0,
                                                "overlayBottomRight", 0.25);
  EXPECT_NEAR((preview.x + preview.width / 2.0) / kPreviewW,
              (exported.x + exported.width / 2.0) / kExportW, 0.0001);
  EXPECT_NEAR((preview.y + preview.height / 2.0) / kPreviewH,
              (exported.y + exported.height / 2.0) / kExportH, 0.0001);
  EXPECT_NEAR(preview.width / kPreviewH, exported.width / kExportH, 0.0001);
}

TEST(CameraParityTest, ManualPlacementIsProportionalAcrossCanvasSizes) {
  // Same check for a dragged bubble, including the y-UP flip — a one-sided
  // flip would show up here as a mismatched normalized centre.
  const auto preview =
      ComputeCameraBubbleRect(kPreviewW, kPreviewH, true, 0.3, 0.8, "", 0.2);
  const auto exported =
      ComputeCameraBubbleRect(kExportW, kExportH, true, 0.3, 0.8, "", 0.2);
  EXPECT_NEAR((preview.x + preview.width / 2.0) / kPreviewW,
              (exported.x + exported.width / 2.0) / kExportW, 0.0001);
  EXPECT_NEAR((preview.y + preview.height / 2.0) / kPreviewH,
              (exported.y + exported.height / 2.0) / kExportH, 0.0001);
}

TEST(CameraParityTest, TheDefaultMinSideFloorIsNonProportional) {
  // kCameraBubbleMinSidePx is ABSOLUTE, so at a small size factor a smaller
  // surface floors where a bigger one does not: 0.08 * 720 = 57.6px floors to
  // 96 here, while 0.08 * 2160 = 172.8px is comfortably above it there.
  //
  // This is a statement about the DEFAULT argument, and it stays true — the
  // floor is still absolute. The preview no longer suffers it, because it
  // passes a floor scaled by its own short-side ratio; see the companion test
  // below and `PreviewCameraEffectScale`.
  const auto preview =
      ComputeCameraBubbleRect(kPreviewW, kPreviewH, false, 0, 0, "", 0.08);
  const auto exported =
      ComputeCameraBubbleRect(kExportW, kExportH, false, 0, 0, "", 0.08);
  EXPECT_NEAR(preview.width, kCameraBubbleMinSidePx, 0.001);
  EXPECT_NEAR(exported.width, kExportH * 0.08, 0.001);
  // Left un-scaled, the smaller surface's bubble is proportionally BIGGER.
  EXPECT_GT(preview.width / kPreviewH, exported.width / kExportH);
}

TEST(CameraParityTest, ScalingTheMinSideFloorRemovesTheDivergence) {
  // The fix for the test above: pass the floor in THIS surface's pixels.
  const double scale = kPreviewH / kExportH;  // 720 / 2160 = 1/3
  const auto preview =
      ComputeCameraBubbleRect(kPreviewW, kPreviewH, false, 0, 0, "", 0.08,
                              kCameraBubbleMinSidePx * scale);
  const auto exported =
      ComputeCameraBubbleRect(kExportW, kExportH, false, 0, 0, "", 0.08);
  EXPECT_NEAR(preview.width / kPreviewH, exported.width / kExportH, 1e-9);
}

TEST(CameraParityTest, Reel916PortraitFloorIsTheWorstCase) {
  // The regression that motivated the fix. Portrait export 1080x1920 previews
  // into a 404x720 texture, so the 96px floor binds for every size factor below
  // 96/404 = 0.238 — i.e. most of the authored [0.08, 0.45] band. At the 0.18
  // default the unscaled preview bubble is 96px = 23.8% of its short side
  // against the export's 18%, a 32% oversize.
  constexpr double kReelPreviewW = 404.0;
  constexpr double kReelPreviewH = 720.0;
  constexpr double kReelExportW = 1080.0;
  constexpr double kReelExportH = 1920.0;
  const double scale = kReelPreviewW / kReelExportW;

  const auto unscaled = ComputeCameraBubbleRect(kReelPreviewW, kReelPreviewH,
                                                false, 0, 0, "", 0.18);
  EXPECT_NEAR(unscaled.width, kCameraBubbleMinSidePx, 0.001);
  EXPECT_NEAR(unscaled.width / kReelPreviewW, 0.2376, 0.001);

  const auto scaled =
      ComputeCameraBubbleRect(kReelPreviewW, kReelPreviewH, false, 0, 0, "",
                              0.18, kCameraBubbleMinSidePx * scale);
  const auto exported = ComputeCameraBubbleRect(kReelExportW, kReelExportH,
                                                false, 0, 0, "", 0.18);
  EXPECT_NEAR(scaled.width / kReelPreviewW, 0.18, 1e-9);
  EXPECT_NEAR(scaled.width / kReelPreviewW, exported.width / kReelExportW,
              1e-9);
}

TEST(CameraExportLayoutTest, MinSideFloorParameterDefaultsToNinetySix) {
  // Guards the export/live no-op: omitting the argument must be identical to
  // passing the constant, or this change would have moved shipped output.
  const auto implicit_arg =
      ComputeCameraBubbleRect(1080.0, 1920.0, false, 0, 0, "", 0.08);
  const auto explicit_arg = ComputeCameraBubbleRect(
      1080.0, 1920.0, false, 0, 0, "", 0.08, kCameraBubbleMinSidePx);
  EXPECT_EQ(implicit_arg.x, explicit_arg.x);
  EXPECT_EQ(implicit_arg.y, explicit_arg.y);
  EXPECT_EQ(implicit_arg.width, explicit_arg.width);
  EXPECT_EQ(implicit_arg.height, explicit_arg.height);
}

TEST(CameraExportLayoutTest, NegativeMinSideFloorIsTreatedAsNoFloor) {
  // std::max with a negative floor would be a no-op, but only by accident;
  // pinned so a future signed-arithmetic slip cannot grow the bubble.
  const auto r =
      ComputeCameraBubbleRect(1000.0, 1000.0, true, 0.5, 0.5, "", 0.08, -500.0);
  EXPECT_NEAR(r.width, 80.0, 0.001);
}

TEST(CameraParityTest, AnimationOutputIsCanvasIndependentExceptTheSlide) {
  // Opacity and scale are pure functions of time and durations, so they must be
  // identical on both canvases. The slide translation and the zoom clamp are
  // canvas-proportional by design, which is why the parity assertion normalizes
  // them rather than comparing raw pixels.
  CameraAnimationParams p =
      MakeParams(CameraIntroKind::kPop, CameraOutroKind::kFade);
  const auto small = ResolveCameraAnimation(
      p, 100, 1000,
      ComputeCameraBubbleRect(kPreviewW, kPreviewH, false, 0, 0, "", 0.25),
      kPreviewW, kPreviewH, CameraSlideEdge::kRight);
  const auto big = ResolveCameraAnimation(
      p, 100, 1000,
      ComputeCameraBubbleRect(kExportW, kExportH, false, 0, 0, "", 0.25),
      kExportW, kExportH, CameraSlideEdge::kRight);
  EXPECT_NEAR(small.opacity, big.opacity, 0.0001);
  EXPECT_NEAR(small.scale, big.scale, 0.0001);
}

TEST(CameraParityTest, SlideTranslationIsProportionalAcrossCanvasSizes) {
  CameraAnimationParams p =
      MakeParams(CameraIntroKind::kSlide, CameraOutroKind::kNone);
  // Mid-intro, so the slide offset is partially applied on both.
  const auto small = ResolveCameraAnimation(
      p, 100, 1000,
      ComputeCameraBubbleRect(kPreviewW, kPreviewH, false, 0, 0, "", 0.25),
      kPreviewW, kPreviewH, CameraSlideEdge::kRight);
  const auto big = ResolveCameraAnimation(
      p, 100, 1000,
      ComputeCameraBubbleRect(kExportW, kExportH, false, 0, 0, "", 0.25),
      kExportW, kExportH, CameraSlideEdge::kRight);
  EXPECT_NEAR(small.translate_x / kPreviewW, big.translate_x / kExportW, 0.001);
}


TEST(CameraIntroKindTest, ParsesKnownNamesAndSoftFails) {
  EXPECT_EQ(ParseCameraIntroKind("fade"), CameraIntroKind::kFade);
  EXPECT_EQ(ParseCameraIntroKind("pop"), CameraIntroKind::kPop);
  EXPECT_EQ(ParseCameraIntroKind("slide"), CameraIntroKind::kSlide);
  EXPECT_EQ(ParseCameraIntroKind("none"), CameraIntroKind::kNone);
  EXPECT_EQ(ParseCameraIntroKind(""), CameraIntroKind::kNone);
  EXPECT_EQ(ParseCameraIntroKind("garbage"), CameraIntroKind::kNone);
  // `shrink` is an OUTRO preset; it is not a valid intro → soft-fail to none.
  EXPECT_EQ(ParseCameraIntroKind("shrink"), CameraIntroKind::kNone);
}

TEST(CameraOutroKindTest, ParsesKnownNamesAndSoftFails) {
  EXPECT_EQ(ParseCameraOutroKind("fade"), CameraOutroKind::kFade);
  EXPECT_EQ(ParseCameraOutroKind("shrink"), CameraOutroKind::kShrink);
  EXPECT_EQ(ParseCameraOutroKind("slide"), CameraOutroKind::kSlide);
  EXPECT_EQ(ParseCameraOutroKind("none"), CameraOutroKind::kNone);
  EXPECT_EQ(ParseCameraOutroKind("pop"), CameraOutroKind::kNone);  // intro-only
  EXPECT_EQ(ParseCameraOutroKind("garbage"), CameraOutroKind::kNone);
}

TEST(CameraSlideEdgeTest, PresetMapping) {
  auto edge = [](const char* preset) {
    return ResolveCameraSlideEdge(preset, /*has_center=*/false, kBubble,
                                  kCanvasW, kCanvasH);
  };
  EXPECT_EQ(edge("overlayTopLeft"), CameraSlideEdge::kLeft);
  EXPECT_EQ(edge("overlayBottomLeft"), CameraSlideEdge::kLeft);
  EXPECT_EQ(edge("overlayTopRight"), CameraSlideEdge::kRight);
  EXPECT_EQ(edge("overlayBottomRight"), CameraSlideEdge::kRight);
  EXPECT_EQ(edge("stackedTop"), CameraSlideEdge::kTop);
  EXPECT_EQ(edge("stackedBottom"), CameraSlideEdge::kBottom);
  EXPECT_EQ(edge("hidden"), CameraSlideEdge::kRight);  // default
}

TEST(CameraSlideEdgeTest, ManualUsesNearestEdge) {
  // Bubble hugging the left edge → slides from the left.
  const CameraBubbleRect left{0.0, 480.0, 120.0, 120.0};
  EXPECT_EQ(ResolveCameraSlideEdge("", true, left, kCanvasW, kCanvasH),
            CameraSlideEdge::kLeft);
  // Bubble hugging the top edge → slides from the top (y-DOWN).
  const CameraBubbleRect top{900.0, 0.0, 120.0, 120.0};
  EXPECT_EQ(ResolveCameraSlideEdge("", true, top, kCanvasW, kCanvasH),
            CameraSlideEdge::kTop);
  // Bubble hugging the bottom edge → slides from the bottom.
  const CameraBubbleRect bottom{900.0, 960.0, 120.0, 120.0};
  EXPECT_EQ(ResolveCameraSlideEdge("", true, bottom, kCanvasW, kCanvasH),
            CameraSlideEdge::kBottom);
}

TEST(CameraSlideEdgeTest, ManualVerticalTieMatchesMacOSBottom) {
  // Dead-center bubble on a landscape canvas: the vertical pair wins
  // (min_vertical 540 < min_horizontal 960) and top/bottom tie exactly.
  // macOS resolves the tie to the visual bottom (y-UP `bottomDistance <=
  // topDistance → .bottom`); the y-DOWN port must agree.
  const CameraBubbleRect centered{kCanvasW / 2.0 - 100.0,
                                  kCanvasH / 2.0 - 100.0, 200.0, 200.0};
  EXPECT_EQ(ResolveCameraSlideEdge("", true, centered, kCanvasW, kCanvasH),
            CameraSlideEdge::kBottom);
}

TEST(CameraAnimationTest, NoPresetsIsIdentity) {
  const auto a =
      Resolve(MakeParams(CameraIntroKind::kNone, CameraOutroKind::kNone), 0);
  EXPECT_DOUBLE_EQ(a.opacity, 1.0);
  EXPECT_DOUBLE_EQ(a.scale, 1.0);
  EXPECT_DOUBLE_EQ(a.translate_x, 0.0);
  EXPECT_DOUBLE_EQ(a.translate_y, 0.0);
}

TEST(CameraAnimationTest, ZeroDurationClipIsIdentity) {
  // Guards the division in the progress helpers.
  const auto a = ResolveCameraAnimation(
      MakeParams(CameraIntroKind::kFade, CameraOutroKind::kFade), 0, 0, kBubble,
      kCanvasW, kCanvasH, CameraSlideEdge::kRight);
  EXPECT_DOUBLE_EQ(a.opacity, 1.0);
}

TEST(CameraAnimationTest, IntroFadeRampsOpacity) {
  const auto p = MakeParams(CameraIntroKind::kFade, CameraOutroKind::kNone);
  EXPECT_NEAR(Resolve(p, 0).opacity, 0.0, 1e-6);     // start fully transparent
  EXPECT_NEAR(Resolve(p, 100).opacity, 0.5, 1e-6);   // half through 200ms intro
  EXPECT_NEAR(Resolve(p, 200).opacity, 1.0, 1e-6);   // intro complete
  EXPECT_NEAR(Resolve(p, 500).opacity, 1.0, 1e-6);   // resting
  // Fade does not scale or translate.
  EXPECT_DOUBLE_EQ(Resolve(p, 100).scale, 1.0);
  EXPECT_DOUBLE_EQ(Resolve(p, 100).translate_x, 0.0);
}

TEST(CameraAnimationTest, IntroPopScalesUpAndFadesIn) {
  const auto p = MakeParams(CameraIntroKind::kPop, CameraOutroKind::kNone);
  const auto start = Resolve(p, 0);
  EXPECT_NEAR(start.scale, 0.90, 1e-6);    // pops from 90%
  EXPECT_NEAR(start.opacity, 0.0, 1e-6);   // pop also fades in
  const auto end = Resolve(p, 200);
  EXPECT_NEAR(end.scale, 1.0, 1e-6);
  EXPECT_NEAR(end.opacity, 1.0, 1e-6);
}

TEST(CameraAnimationTest, OutroFadeAndShrinkPlayAtEnd) {
  // Resting at mid-clip: nothing applied yet.
  const auto fade = MakeParams(CameraIntroKind::kNone, CameraOutroKind::kFade);
  EXPECT_NEAR(Resolve(fade, 500).opacity, 1.0, 1e-6);
  EXPECT_NEAR(Resolve(fade, 900).opacity, 0.5, 1e-6);  // half through 200ms outro
  EXPECT_NEAR(Resolve(fade, 1000).opacity, 0.0, 1e-6);  // fully gone at the end

  const auto shrink =
      MakeParams(CameraIntroKind::kNone, CameraOutroKind::kShrink);
  EXPECT_NEAR(Resolve(shrink, 500).scale, 1.0, 1e-6);   // resting
  EXPECT_NEAR(Resolve(shrink, 1000).scale, 0.90, 1e-6);  // shrunk at the end
}

TEST(CameraAnimationTest, SlideIntroEntersFromEdgeThenRests) {
  const auto p = MakeParams(CameraIntroKind::kSlide, CameraOutroKind::kNone);
  // Right edge offscreen offset = canvasW + margin - bubble.x.
  const double off = kCanvasW + 1.0 - kBubble.x;  // 321
  const auto start = Resolve(p, 0, CameraSlideEdge::kRight);
  EXPECT_NEAR(start.translate_x, off, 1e-6);  // starts fully off the right edge
  EXPECT_NEAR(start.translate_y, 0.0, 1e-6);
  const auto end = Resolve(p, 200, CameraSlideEdge::kRight);
  EXPECT_NEAR(end.translate_x, 0.0, 1e-6);  // settled into place
  // Slide ramps opacity in too (matches macOS).
  EXPECT_NEAR(start.opacity, 0.0, 1e-6);
  EXPECT_NEAR(end.opacity, 1.0, 1e-6);
}

TEST(CameraAnimationTest, SlideOutroExitsTowardEdge) {
  const auto p = MakeParams(CameraIntroKind::kNone, CameraOutroKind::kSlide);
  const double off = kCanvasW + 1.0 - kBubble.x;
  EXPECT_NEAR(Resolve(p, 500, CameraSlideEdge::kRight).translate_x, 0.0, 1e-6);
  EXPECT_NEAR(Resolve(p, 1000, CameraSlideEdge::kRight).translate_x, off, 1e-6);
}

TEST(CameraAnimationTest, SlideTopOutroMovesUpInYDown) {
  const auto p = MakeParams(CameraIntroKind::kNone, CameraOutroKind::kSlide);
  // Top edge in y-DOWN pushes the bubble to a NEGATIVE y offset.
  const auto end = Resolve(p, 1000, CameraSlideEdge::kTop);
  EXPECT_LT(end.translate_y, 0.0);
  EXPECT_NEAR(end.translate_x, 0.0, 1e-6);
}

TEST(CameraAnimationTest, FrameTimeIsClampedToClip) {
  const auto p = MakeParams(CameraIntroKind::kFade, CameraOutroKind::kFade);
  // Past the end clamps to the final outro state, not beyond.
  EXPECT_NEAR(Resolve(p, 5000).opacity, 0.0, 1e-6);
  // Negative time clamps to the intro start.
  EXPECT_NEAR(Resolve(p, -100).opacity, 0.0, 1e-6);
}

}  // namespace

// --- scale with screen zoom -------------------------------------------------

TEST(ResolveCameraZoomScale, GrowsWithTheZoomExcessTimesTheMultiplier) {
  // macOS CameraTransformTimelineBuilder.resolvedScale: the bubble adopts
  // `multiplier` of the zoom's excess. Default 0.35 at a 2.0x screen zoom.
  EXPECT_NEAR(
      ResolveCameraZoomScale("scaleWithScreenZoom", 0.35, 2.0, "overlayBottomRight"),
      1.35, 0.0001);
  EXPECT_NEAR(
      ResolveCameraZoomScale("scaleWithScreenZoom", 1.0, 2.0, "overlayBottomRight"),
      2.0, 0.0001);
  EXPECT_NEAR(
      ResolveCameraZoomScale("scaleWithScreenZoom", 0.0, 3.0, "overlayBottomRight"),
      1.0, 0.0001);  // multiplier 0 == fixed
}

TEST(ResolveCameraZoomScale, FixedAndUnknownBehavioursDoNotScale) {
  EXPECT_DOUBLE_EQ(ResolveCameraZoomScale("fixed", 1.0, 3.0, "overlayTopLeft"), 1.0);
  EXPECT_DOUBLE_EQ(ResolveCameraZoomScale("", 1.0, 3.0, "overlayTopLeft"), 1.0);
  // A future behaviour name this binary predates must not silently scale.
  EXPECT_DOUBLE_EQ(
      ResolveCameraZoomScale("orbitTheCursor", 1.0, 3.0, "overlayTopLeft"), 1.0);
}

TEST(ResolveCameraZoomScale, BackgroundBehindOptsOut) {
  // A full-canvas camera has no meaningful "grow with the zoom" (macOS guards
  // the same preset).
  EXPECT_DOUBLE_EQ(
      ResolveCameraZoomScale("scaleWithScreenZoom", 1.0, 3.0, "backgroundBehind"),
      1.0);
}

TEST(ResolveCameraZoomScale, NeverShrinksBelowTheAuthoredSize) {
  // A zoom-out, or a smoother undershoot, must not shrink the bubble.
  EXPECT_DOUBLE_EQ(
      ResolveCameraZoomScale("scaleWithScreenZoom", 1.0, 0.5, "overlayTopLeft"),
      1.0);
  EXPECT_DOUBLE_EQ(
      ResolveCameraZoomScale("scaleWithScreenZoom", 1.0, 1.0, "overlayTopLeft"),
      1.0);
  // Out-of-range multipliers clamp rather than inverting the effect.
  EXPECT_NEAR(
      ResolveCameraZoomScale("scaleWithScreenZoom", -2.0, 3.0, "overlayTopLeft"),
      1.0, 0.0001);
  EXPECT_NEAR(
      ResolveCameraZoomScale("scaleWithScreenZoom", 9.0, 3.0, "overlayTopLeft"),
      3.0, 0.0001);
}

TEST(CameraAnimationTest, ZoomScaleAppliesWithNoIntroOrOutro) {
  // The zoom scale is not gated on a preset or on a known duration: a clip
  // whose duration has not resolved yet still scales with the zoom rather than
  // popping to its resting size.
  CameraAnimationParams p;
  p.zoom_scale = 1.4;
  const auto out = ResolveCameraAnimation(p, 0, 0, kBubble, kCanvasW, kCanvasH,
                                          CameraSlideEdge::kRight);
  EXPECT_NEAR(out.scale, 1.4, 0.0001);
  EXPECT_DOUBLE_EQ(out.opacity, 1.0);
}

TEST(CameraAnimationTest, ZoomScaleComposesWithThePopIntro) {
  // Both are uniform scales about the same centre, so they multiply — macOS
  // composes additionalScale on top of the zoom-scaled frame the same way.
  CameraAnimationParams p = MakeParams(CameraIntroKind::kPop,
                                       CameraOutroKind::kNone);
  p.zoom_scale = 1.5;
  // t=0 → pop scale is exactly 0.90.
  const auto out = Resolve(p, 0);
  EXPECT_NEAR(out.scale, 1.5 * 0.90, 0.0001);
}

TEST(CameraAnimationTest, AnIdentityZoomLeavesTheStaticBubbleUntouched) {
  // The un-zoomed, un-animated case must stay exactly identity so the painter
  // keeps taking its byte-identical fast path.
  CameraAnimationParams p;
  p.zoom_scale = 1.0;
  const auto out = Resolve(p, 500);
  EXPECT_DOUBLE_EQ(out.scale, 1.0);
  EXPECT_DOUBLE_EQ(out.opacity, 1.0);
  EXPECT_DOUBLE_EQ(out.translate_x, 0.0);
  EXPECT_DOUBLE_EQ(out.translate_y, 0.0);
}

TEST(CameraAnimationTest, ScalingUpNudgesACornerBubbleBackOnCanvas) {
  // kBubble is centred at x=1700 on a 1920-wide canvas. At 2x it still fits
  // (half-width 200, right edge 1900), so nothing should move. At 3x the half
  // -width is 300 and the right edge would reach 2000, so the centre must be
  // pulled back to 1620 — a translate of -80.
  CameraAnimationParams fits;
  fits.zoom_scale = 2.0;
  EXPECT_DOUBLE_EQ(ResolveCameraAnimation(fits, 0, 0, kBubble, kCanvasW,
                                          kCanvasH, CameraSlideEdge::kRight)
                       .translate_x,
                   0.0);

  CameraAnimationParams spills;
  spills.zoom_scale = 3.0;
  const auto out = ResolveCameraAnimation(spills, 0, 0, kBubble, kCanvasW,
                                          kCanvasH, CameraSlideEdge::kRight);
  const double cx = kBubble.x + kBubble.width / 2.0;
  const double half = (kBubble.width * 3.0) / 2.0;
  EXPECT_NEAR(cx + out.translate_x, kCanvasW - half, 0.001);
  EXPECT_NEAR(out.translate_x, -80.0, 0.001);  // pulled LEFT, back inside
}

TEST(CameraAnimationTest, TheClampDoesNotCancelTheSlideOutro) {
  // THE trap this ordering exists to avoid: clamping AFTER the slide would drag
  // a slide-out bubble back on-screen and silently kill the outro. The clamp
  // offset and the slide offset must simply ADD, so the bubble still travels
  // its full distance off-canvas even while the zoom clamp is pulling it in.
  CameraAnimationParams p =
      MakeParams(CameraIntroKind::kNone, CameraOutroKind::kSlide);
  const auto plain = Resolve(p, kTotalMs, CameraSlideEdge::kRight);
  EXPECT_GT(plain.translate_x, 0.0);  // the outro travels right, off-canvas

  p.zoom_scale = 3.0;  // the same 3x that clamps the resting centre by -80
  const auto zoomed = Resolve(p, kTotalMs, CameraSlideEdge::kRight);
  EXPECT_NEAR(zoomed.translate_x, plain.translate_x - 80.0, 0.001);
}

}  // namespace clingfy::capture
