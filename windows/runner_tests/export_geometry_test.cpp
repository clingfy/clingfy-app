#include "Capture/Export/export_geometry.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <optional>
#include <string>

namespace clingfy::capture::export_ {
namespace {

// Tolerance for the floating-point geometry asserts. The real encoder
// contract is the integer `ToEvenPixelSize` output (asserted exactly
// below); the SizeF / RectF comparisons only need to be tight enough to
// catch a wrong aspect, swapped axis, or fit/fill mix-up without tripping
// on last-ULP noise from `4.0/3.0`-style divisions.
constexpr double kEps = 1e-3;

// ---- ResolveTargetSize: layout aspect x resolution short-side ---------------
//
// Ported 1:1 from macos/RunnerTests/ExportPrepTests.swift
// (testResolveTargetSizePresetAspectsAndResolutions /
//  testResolveTargetSizeAutoFallsBackToSource) so Windows frames a
// recording identically to macOS.

TEST(ResolveTargetSizeTest, Youtube169At1080MatchesSource) {
  const SizeF out = ResolveTargetSize({1920.0, 1080.0}, "youtube169", "p1080");
  EXPECT_NEAR(out.width, 1920.0, kEps);
  EXPECT_NEAR(out.height, 1080.0, kEps);
}

TEST(ResolveTargetSizeTest, Square11At1080IsSquare) {
  const SizeF out = ResolveTargetSize({1920.0, 1080.0}, "square11", "p1080");
  EXPECT_NEAR(out.width, 1080.0, kEps);
  EXPECT_NEAR(out.height, 1080.0, kEps);
}

TEST(ResolveTargetSizeTest, Reel916At1080IsPortrait) {
  const SizeF out = ResolveTargetSize({1920.0, 1080.0}, "reel916", "p1080");
  EXPECT_NEAR(out.width, 1080.0, kEps);
  EXPECT_NEAR(out.height, 1920.0, kEps);
}

TEST(ResolveTargetSizeTest, Classic43At1440UsesShortSideAsHeight) {
  const SizeF out = ResolveTargetSize({1920.0, 1080.0}, "classic43", "p1440");
  EXPECT_NEAR(out.width, 1440.0 * 4.0 / 3.0, kEps);  // 1920
  EXPECT_NEAR(out.height, 1440.0, kEps);
}

TEST(ResolveTargetSizeTest, AutoLayoutAutoResolutionReturnsSource) {
  const SizeF out = ResolveTargetSize({1280.0, 720.0}, "auto", "auto");
  EXPECT_NEAR(out.width, 1280.0, kEps);
  EXPECT_NEAR(out.height, 720.0, kEps);
}

TEST(ResolveTargetSizeTest, EmptyArgsAreTreatedAsAuto) {
  // The router passes through whatever Dart sends; empty strings (a
  // not-yet-wired caller) must behave like "auto", not crash or zero out.
  const SizeF out = ResolveTargetSize({1600.0, 900.0}, "", "");
  EXPECT_NEAR(out.width, 1600.0, kEps);
  EXPECT_NEAR(out.height, 900.0, kEps);
}

TEST(ResolveTargetSizeTest, AutoLayout1080DownscalesPreservingSourceAspect) {
  // 4K 16:9 source, auto layout (-> source aspect), 1080 short side.
  const SizeF out = ResolveTargetSize({3840.0, 2160.0}, "auto", "p1080");
  EXPECT_NEAR(out.width, 1920.0, kEps);
  EXPECT_NEAR(out.height, 1080.0, kEps);
}

TEST(ResolveTargetSizeTest, Youtube169At2160IsUhd) {
  const SizeF out = ResolveTargetSize({1920.0, 1080.0}, "youtube169", "p2160");
  EXPECT_NEAR(out.width, 3840.0, kEps);
  EXPECT_NEAR(out.height, 2160.0, kEps);
}

TEST(ResolveTargetSizeTest, Reel916At1440IsTallPortrait) {
  // 9:16 aspect, short side 1440 -> width 1440, height 1440 / 0.5625 = 2560.
  const SizeF out = ResolveTargetSize({1920.0, 1080.0}, "reel916", "p1440");
  EXPECT_NEAR(out.width, 1440.0, kEps);
  EXPECT_NEAR(out.height, 2560.0, kEps);
}

TEST(ResolveTargetSizeTest, Square11AutoResolutionExpandsToSourceWidthSquare) {
  // square aspect (1.0) is narrower than the 16:9 source aspect, so the
  // macOS "auto" branch keeps source width and expands height to match.
  const SizeF out = ResolveTargetSize({1920.0, 1080.0}, "square11", "auto");
  EXPECT_NEAR(out.width, 1920.0, kEps);
  EXPECT_NEAR(out.height, 1920.0, kEps);
}

TEST(ResolveTargetSizeTest, DegenerateSourceWithAutoResolutionReturnsSource) {
  const SizeF out = ResolveTargetSize({0.0, 0.0}, "youtube169", "auto");
  EXPECT_NEAR(out.width, 0.0, kEps);
  EXPECT_NEAR(out.height, 0.0, kEps);
}

// ---- ToEvenPixelSize: encoder-ready rounding --------------------------------

TEST(ToEvenPixelSizeTest, ExactEvenValuesPassThrough) {
  const PixelSize out = ToEvenPixelSize({1920.0, 1080.0});
  EXPECT_EQ(out.width, 1920u);
  EXPECT_EQ(out.height, 1080u);
}

TEST(ToEvenPixelSizeTest, OddIntegersRoundUpToEven) {
  const PixelSize out = ToEvenPixelSize({1081.0, 721.0});
  EXPECT_EQ(out.width, 1082u);
  EXPECT_EQ(out.height, 722u);
}

TEST(ToEvenPixelSizeTest, FractionalRoundsToNearestThenEven) {
  // 1919.4 -> 1919 (odd) -> 1920; 1080.6 -> 1081 (odd) -> 1082.
  const PixelSize out = ToEvenPixelSize({1919.4, 1080.6});
  EXPECT_EQ(out.width, 1920u);
  EXPECT_EQ(out.height, 1082u);
}

TEST(ToEvenPixelSizeTest, ClampsDegenerateToTwo) {
  EXPECT_EQ(ToEvenPixelSize({0.0, 0.0}).width, 2u);
  EXPECT_EQ(ToEvenPixelSize({0.0, 0.0}).height, 2u);
  EXPECT_EQ(ToEvenPixelSize({1.0, 1.4}).width, 2u);
}

TEST(ToEvenPixelSizeTest, Reel916At1440EvenizesCleanly) {
  const PixelSize out = ToEvenPixelSize(
      ResolveTargetSize({1920.0, 1080.0}, "reel916", "p1440"));
  EXPECT_EQ(out.width, 1440u);
  EXPECT_EQ(out.height, 2560u);
}

// ---- ComputeContentRect: fit / fill scale + centering -----------------------

TEST(ComputeContentRectTest, IdenticalSizeFitFillsExactly) {
  const RectF r =
      ComputeContentRect({1920.0, 1080.0}, {1920.0, 1080.0}, FitMode::kFit);
  EXPECT_NEAR(r.x, 0.0, kEps);
  EXPECT_NEAR(r.y, 0.0, kEps);
  EXPECT_NEAR(r.width, 1920.0, kEps);
  EXPECT_NEAR(r.height, 1080.0, kEps);
}

TEST(ComputeContentRectTest, WideSourceIntoSquareFitLetterboxes) {
  // 1920x1080 into a 1080x1080 canvas, fit: scale = min(0.5625, 1.0) =
  // 0.5625 -> content 1080x607.5, centered vertically (bars top/bottom).
  const RectF r =
      ComputeContentRect({1080.0, 1080.0}, {1920.0, 1080.0}, FitMode::kFit);
  EXPECT_NEAR(r.width, 1080.0, kEps);
  EXPECT_NEAR(r.height, 607.5, kEps);
  EXPECT_NEAR(r.x, 0.0, kEps);
  EXPECT_NEAR(r.y, 236.25, kEps);
}

TEST(ComputeContentRectTest, WideSourceIntoSquareFillCropsSides) {
  // Same inputs, fill: scale = max(0.5625, 1.0) = 1.0 -> content
  // 1920x1080 overflowing the 1080-wide canvas; x is negative (cropped).
  const RectF r =
      ComputeContentRect({1080.0, 1080.0}, {1920.0, 1080.0}, FitMode::kFill);
  EXPECT_NEAR(r.width, 1920.0, kEps);
  EXPECT_NEAR(r.height, 1080.0, kEps);
  EXPECT_NEAR(r.x, -420.0, kEps);
  EXPECT_NEAR(r.y, 0.0, kEps);
}

TEST(ComputeContentRectTest, WideSourceIntoPortraitFitCentersVertically) {
  // 1920x1080 into a 1080x1920 reel canvas, fit: scale = min(0.5625,
  // 1.777..) = 0.5625 -> content 1080x607.5 centered tall.
  const RectF r =
      ComputeContentRect({1080.0, 1920.0}, {1920.0, 1080.0}, FitMode::kFit);
  EXPECT_NEAR(r.width, 1080.0, kEps);
  EXPECT_NEAR(r.height, 607.5, kEps);
  EXPECT_NEAR(r.x, 0.0, kEps);
  EXPECT_NEAR(r.y, 656.25, kEps);
}

TEST(ComputeContentRectTest, PaddingShrinksAndRecentersContent) {
  // 40px symmetric padding on a square canvas: available 1000x1000, scale
  // = min(1000/1920, 1000/1080) = 0.5208.. -> content 1000x562.5 centered.
  const RectF r = ComputeContentRect({1080.0, 1080.0}, {1920.0, 1080.0},
                                     FitMode::kFit, 40.0);
  EXPECT_NEAR(r.width, 1000.0, kEps);
  EXPECT_NEAR(r.height, 562.5, kEps);
  EXPECT_NEAR(r.x, 40.0, kEps);
  EXPECT_NEAR(r.y, (1080.0 - 562.5) / 2.0, kEps);
}

TEST(ComputeContentRectTest, PaddingWithFillCoversAvailableAndCropsWidth) {
  // 40px padding, fill: available 1000x1000, scale = max(1000/1920,
  // 1000/1080) = 1000/1080 -> content fills the available height (1000) and
  // overflows width, so x goes negative (cropped) while the top/bottom land
  // at the padding margin.
  const RectF r = ComputeContentRect({1080.0, 1080.0}, {1920.0, 1080.0},
                                     FitMode::kFill, 40.0);
  const double scale = 1000.0 / 1080.0;
  EXPECT_NEAR(r.width, 1920.0 * scale, kEps);
  EXPECT_NEAR(r.height, 1000.0, kEps);
  EXPECT_NEAR(r.y, 40.0, kEps);
  EXPECT_NEAR(r.x, (1080.0 - 1920.0 * scale) / 2.0, kEps);
}

TEST(ComputeContentRectTest, OversizedPaddingClampsAvailableToFloor) {
  // Padding larger than the canvas: each axis is clamped to the >= 1 floor
  // rather than going negative, collapsing the content to a sliver instead
  // of inverting it.
  const RectF r = ComputeContentRect({1080.0, 1080.0}, {1920.0, 1080.0},
                                     FitMode::kFit, 2000.0);
  const double scale = 1.0 / 1920.0;  // available 1x1 -> min scale on width
  EXPECT_NEAR(r.width, 1920.0 * scale, kEps);   // 1.0
  EXPECT_NEAR(r.height, 1080.0 * scale, kEps);  // 0.5625
}

TEST(ComputeContentRectTest, PaddingOnPortraitCanvasInsetsBothAxes) {
  // 30px padding on a 1080x1920 reel canvas, fit: available 1020x1860,
  // scale = min(1020/1920, 1860/1080) = 1020/1920 -> the fitted (width)
  // axis margin equals padding; the letterboxed axis is centered tall.
  const RectF r = ComputeContentRect({1080.0, 1920.0}, {1920.0, 1080.0},
                                     FitMode::kFit, 30.0);
  const double scale = 1020.0 / 1920.0;
  EXPECT_NEAR(r.width, 1020.0, kEps);
  EXPECT_NEAR(r.height, 1080.0 * scale, kEps);  // 573.75
  EXPECT_NEAR(r.x, 30.0, kEps);
  EXPECT_NEAR(r.y, (1920.0 - 1080.0 * scale) / 2.0, kEps);
}

// ---- ResolveBackgroundColor: ARGB int -> RGBA (macOS parity) ----------------

TEST(ResolveBackgroundColorTest, NulloptIsOpaqueBlack) {
  const RgbaColor c = ResolveBackgroundColor(std::nullopt);
  EXPECT_NEAR(c.r, 0.0, kEps);
  EXPECT_NEAR(c.g, 0.0, kEps);
  EXPECT_NEAR(c.b, 0.0, kEps);
  EXPECT_NEAR(c.a, 1.0, kEps);
}

TEST(ResolveBackgroundColorTest, OpaqueArgbDecodesEachChannel) {
  // 0xFF3366CC -> r=0x33/255, g=0x66/255, b=0xCC/255, a=1.
  const RgbaColor c = ResolveBackgroundColor(std::int64_t{0xFF3366CC});
  EXPECT_NEAR(c.r, 0x33 / 255.0, kEps);
  EXPECT_NEAR(c.g, 0x66 / 255.0, kEps);
  EXPECT_NEAR(c.b, 0xCC / 255.0, kEps);
  EXPECT_NEAR(c.a, 1.0, kEps);
}

TEST(ResolveBackgroundColorTest, ValueWithoutAlphaByteIsTreatedOpaque) {
  // 0x00FF00 (<= 0x00FFFFFF) -> opaque green, matching the macOS rule that
  // a value with no high alpha byte is fully opaque, not transparent.
  const RgbaColor c = ResolveBackgroundColor(std::int64_t{0x0000FF00});
  EXPECT_NEAR(c.r, 0.0, kEps);
  EXPECT_NEAR(c.g, 1.0, kEps);
  EXPECT_NEAR(c.b, 0.0, kEps);
  EXPECT_NEAR(c.a, 1.0, kEps);
}

TEST(ResolveBackgroundColorTest, ZeroIsOpaqueBlackNotTransparent) {
  const RgbaColor c = ResolveBackgroundColor(std::int64_t{0});
  EXPECT_NEAR(c.r, 0.0, kEps);
  EXPECT_NEAR(c.a, 1.0, kEps);
}

TEST(ResolveBackgroundColorTest, HighAlphaByteDecodesTranslucency) {
  // 0x80FF0000 carries a real alpha byte (value > 0x00FFFFFF) -> a≈0.502.
  const RgbaColor c = ResolveBackgroundColor(std::int64_t{0x80FF0000});
  EXPECT_NEAR(c.r, 1.0, kEps);
  EXPECT_NEAR(c.g, 0.0, kEps);
  EXPECT_NEAR(c.b, 0.0, kEps);
  EXPECT_NEAR(c.a, 0x80 / 255.0, kEps);
}

TEST(ResolveBackgroundColorTest, SignExtendedInt32IsMaskedToArgb) {
  // Flutter encodes an ARGB with the alpha high bit set as a negative
  // int32; after sign-extension to int64 the low 32 bits must still read as
  // 0xFF3366CC.
  const std::int64_t sign_extended = static_cast<std::int32_t>(0xFF3366CCu);
  const RgbaColor c = ResolveBackgroundColor(sign_extended);
  EXPECT_NEAR(c.r, 0x33 / 255.0, kEps);
  EXPECT_NEAR(c.g, 0x66 / 255.0, kEps);
  EXPECT_NEAR(c.b, 0xCC / 255.0, kEps);
  EXPECT_NEAR(c.a, 1.0, kEps);
}

// ---- ResolveCornerRadiusPx: clamp to a sane range ---------------------------

TEST(ResolveCornerRadiusPxTest, ZeroAndNegativeClampToZero) {
  const RectF rect{0.0, 0.0, 100.0, 80.0};
  EXPECT_NEAR(ResolveCornerRadiusPx(0.0, rect), 0.0, kEps);
  EXPECT_NEAR(ResolveCornerRadiusPx(-5.0, rect), 0.0, kEps);
}

TEST(ResolveCornerRadiusPxTest, SmallRadiusPassesThrough) {
  const RectF rect{0.0, 0.0, 100.0, 80.0};
  EXPECT_NEAR(ResolveCornerRadiusPx(10.0, rect), 10.0, kEps);
}

TEST(ResolveCornerRadiusPxTest, ClampsToHalfTheShorterSide) {
  // Shorter side is 80 -> max radius 40.
  const RectF rect{0.0, 0.0, 100.0, 80.0};
  EXPECT_NEAR(ResolveCornerRadiusPx(60.0, rect), 40.0, kEps);
}

TEST(ResolveCornerRadiusPxTest, DegenerateRectClampsToZero) {
  const RectF rect{0.0, 0.0, 0.0, 0.0};
  EXPECT_NEAR(ResolveCornerRadiusPx(10.0, rect), 0.0, kEps);
}

// ---- ParseFitMode -----------------------------------------------------------

TEST(ParseFitModeTest, FillVariantsParseToFill) {
  EXPECT_EQ(ParseFitMode("fill"), FitMode::kFill);
  EXPECT_EQ(ParseFitMode("FILL"), FitMode::kFill);
  EXPECT_EQ(ParseFitMode("Fill"), FitMode::kFill);
}

TEST(ParseFitModeTest, FitAndUnknownAndEmptyDefaultToFit) {
  EXPECT_EQ(ParseFitMode("fit"), FitMode::kFit);
  EXPECT_EQ(ParseFitMode(""), FitMode::kFit);
  EXPECT_EQ(ParseFitMode("stretch"), FitMode::kFit);
}

// ---- IsIdentityTransform: copy fast-path gate -------------------------------

TEST(IsIdentityTransformTest, AutoAutoIsIdentity) {
  EXPECT_TRUE(IsIdentityTransform("auto", "auto"));
}

TEST(IsIdentityTransformTest, EmptyArgsAreIdentity) {
  EXPECT_TRUE(IsIdentityTransform("", ""));
  EXPECT_TRUE(IsIdentityTransform("auto", ""));
  EXPECT_TRUE(IsIdentityTransform("", "auto"));
}

TEST(IsIdentityTransformTest, AnyLayoutOrResolutionChangeIsNotIdentity) {
  EXPECT_FALSE(IsIdentityTransform("youtube169", "auto"));
  EXPECT_FALSE(IsIdentityTransform("auto", "p1080"));
  EXPECT_FALSE(IsIdentityTransform("classic43", "p1440"));
  EXPECT_FALSE(IsIdentityTransform("square11", ""));
}

}  // namespace
}  // namespace clingfy::capture::export_
