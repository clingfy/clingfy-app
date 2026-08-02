#include "Core/canvas_composition.h"

#include <gtest/gtest.h>

namespace clingfy::core {
namespace {

// The two surfaces that must agree. Export target is the user's chosen
// resolution; the preview texture is capped (preview_engine.cpp kTextureWidth /
// kTextureHeight). Both use the CANVAS aspect, so their shorter sides are what
// the contract normalises against.
constexpr double kExport4kShort = 2160.0;   // 3840x2160
constexpr double kExport1080Short = 1080.0; // 1920x1080
constexpr double kPreviewShort = 720.0;     // 1280x720

TEST(CanvasCompositionTest, RoundTripsThroughTheSameSurface) {
  const double f = NormalizeToShortSide(100.0, kExport4kShort);
  EXPECT_NEAR(DenormalizeFromShortSide(f, kExport4kShort), 100.0, 1e-9);
}

// The regression this type exists for. Before normalisation, padding=100 was
// handed to both surfaces unchanged: 100px on a 3840-wide export is a thin
// border, 100px on a 1280-wide preview is ~3x thicker. The preview lied, and it
// lied MORE the higher the user's export resolution.
TEST(CanvasCompositionTest, SamePaddingLooksProportionallyIdenticalOnBothSurfaces) {
  constexpr double kPaddingPx = 100.0;
  const CanvasComposition c =
      MakeCanvasComposition(kPaddingPx, 0.0, kExport4kShort, std::nullopt);

  const double on_export = DenormalizeFromShortSide(c.padding_fraction, kExport4kShort);
  const double on_preview = DenormalizeFromShortSide(c.padding_fraction, kPreviewShort);

  // Export keeps the authored value.
  EXPECT_NEAR(on_export, kPaddingPx, 1e-9);
  // Preview scales by exactly the surface ratio (720/2160 = 1/3).
  EXPECT_NEAR(on_preview, kPaddingPx * (kPreviewShort / kExport4kShort), 1e-9);
  // Proportion of the surface is identical — that is the WYSIWYG property.
  EXPECT_NEAR(on_export / kExport4kShort, on_preview / kPreviewShort, 1e-12);
}

// The error used to scale with export resolution: correct-looking at 720p and
// visibly wrong at 4K. The fraction must be independent of which resolution the
// user picked, so the preview looks the same at every export setting.
TEST(CanvasCompositionTest, PreviewFramingIsIndependentOfExportResolution) {
  const CanvasComposition at4k =
      MakeCanvasComposition(200.0, 0.0, kExport4kShort, std::nullopt);
  const CanvasComposition at1080 =
      MakeCanvasComposition(100.0, 0.0, kExport1080Short, std::nullopt);

  // 200px on a 2160-short canvas and 100px on a 1080-short canvas are the SAME
  // framing, so they must land on the same preview pixels.
  EXPECT_NEAR(DenormalizeFromShortSide(at4k.padding_fraction, kPreviewShort),
              DenormalizeFromShortSide(at1080.padding_fraction, kPreviewShort),
              1e-9);
}

TEST(CanvasCompositionTest, CornerRadiusNormalizesOnTheSameBasis) {
  const CanvasComposition c =
      MakeCanvasComposition(0.0, 48.0, kExport1080Short, std::nullopt);
  EXPECT_NEAR(DenormalizeFromShortSide(c.corner_radius_fraction, kExport1080Short),
              48.0, 1e-9);
  EXPECT_NEAR(DenormalizeFromShortSide(c.corner_radius_fraction, kPreviewShort),
              48.0 * (kPreviewShort / kExport1080Short), 1e-9);
}

TEST(CanvasCompositionTest, BackgroundPassesThroughUntouched) {
  const CanvasComposition set =
      MakeCanvasComposition(0.0, 0.0, kPreviewShort, std::optional<std::int64_t>{0xFF102030});
  ASSERT_TRUE(set.background_argb.has_value());
  EXPECT_EQ(*set.background_argb, 0xFF102030);

  // nullopt is the Dart default and must stay nullopt so ResolveBackgroundColor
  // applies its opaque-black rule rather than seeing a fabricated value.
  const CanvasComposition unset =
      MakeCanvasComposition(0.0, 0.0, kPreviewShort, std::nullopt);
  EXPECT_FALSE(unset.background_argb.has_value());
}

// A degenerate surface must not divide by zero or clamp the content away. The
// preview legitimately has no known canvas before the first frame.
TEST(CanvasCompositionTest, DegenerateSurfaceYieldsNoPaddingInsteadOfNonsense) {
  EXPECT_EQ(NormalizeToShortSide(100.0, 0.0), 0.0);
  EXPECT_EQ(NormalizeToShortSide(100.0, -1.0), 0.0);
  EXPECT_EQ(DenormalizeFromShortSide(0.25, 0.0), 0.0);
  EXPECT_EQ(DenormalizeFromShortSide(0.25, -1.0), 0.0);
}

// Dart clamps these, but the contract is the boundary — a negative arriving here
// must not invert the content rect.
TEST(CanvasCompositionTest, NegativeInputsClampToZero) {
  EXPECT_EQ(NormalizeToShortSide(-50.0, kPreviewShort), 0.0);
  EXPECT_EQ(DenormalizeFromShortSide(-0.5, kPreviewShort), 0.0);

  const CanvasComposition c =
      MakeCanvasComposition(-10.0, -10.0, kPreviewShort, std::nullopt);
  EXPECT_EQ(c.padding_fraction, 0.0);
  EXPECT_EQ(c.corner_radius_fraction, 0.0);
}

}  // namespace
}  // namespace clingfy::core
