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
}  // namespace clingfy::capture
