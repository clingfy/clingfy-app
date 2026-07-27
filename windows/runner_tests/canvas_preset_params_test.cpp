#include "Capture/Background/canvas_preset_params.h"

#include <gtest/gtest.h>

#include <set>

namespace clingfy::capture::background {
namespace {

constexpr int kPaletteSize = 5;  // every catalog palette has 5 colours

// ---------------------------------------------------------------------------
// graphicMesh
// ---------------------------------------------------------------------------

// macOS: blobCount = max(6, colors.count + 2). With 5 colours that is 7.
// The count is part of the look — fewer blobs read as discrete circles rather
// than a blended mesh.
TEST(GraphicMeshParamsTest, BlobCountMatchesTheMacOSFormula) {
  EXPECT_EQ(DeriveGraphicMeshParams(1, 0.7, kPaletteSize).blobs.size(), 7u);
  // The max(6, ...) floor bites for small palettes: 3 + 2 = 5, floored to 6.
  EXPECT_EQ(DeriveGraphicMeshParams(1, 0.7, 3).blobs.size(), 6u);
  EXPECT_EQ(DeriveGraphicMeshParams(1, 0.7, 1).blobs.size(), 6u);
}

// The whole point of a seeded generator: same seed, same picture, forever.
// A project reopened next year must render the background it was exported with.
TEST(GraphicMeshParamsTest, IsDeterministicForASeed) {
  const auto a = DeriveGraphicMeshParams(42, 0.7, kPaletteSize);
  const auto b = DeriveGraphicMeshParams(42, 0.7, kPaletteSize);
  ASSERT_EQ(a.blobs.size(), b.blobs.size());
  for (size_t i = 0; i < a.blobs.size(); ++i) {
    EXPECT_DOUBLE_EQ(a.blobs[i].center_x_fraction, b.blobs[i].center_x_fraction);
    EXPECT_DOUBLE_EQ(a.blobs[i].center_y_fraction, b.blobs[i].center_y_fraction);
    EXPECT_DOUBLE_EQ(a.blobs[i].radius_fraction, b.blobs[i].radius_fraction);
  }
}

TEST(GraphicMeshParamsTest, DifferentSeedsScatterDifferently) {
  const auto a = DeriveGraphicMeshParams(1, 0.7, kPaletteSize);
  const auto b = DeriveGraphicMeshParams(2, 0.7, kPaletteSize);
  ASSERT_FALSE(a.blobs.empty());
  EXPECT_NE(a.blobs[0].center_x_fraction, b.blobs[0].center_x_fraction);
}

// Centres deliberately run outside [0,1] so blobs bleed off the edges. If this
// ever gets clamped, every mesh becomes a ring of circles inside the frame.
TEST(GraphicMeshParamsTest, BlobsAreAllowedToBleedOffTheEdges) {
  const auto p = DeriveGraphicMeshParams(3, 0.7, kPaletteSize);
  for (const auto& blob : p.blobs) {
    EXPECT_GE(blob.center_x_fraction, -0.1);
    EXPECT_LE(blob.center_x_fraction, 1.1);
    EXPECT_GE(blob.center_y_fraction, -0.1);
    EXPECT_LE(blob.center_y_fraction, 1.1);
    EXPECT_GE(blob.radius_fraction, 0.45);
    EXPECT_LE(blob.radius_fraction, 0.95);
  }
}

// A fully opaque blob would erase everything under it, collapsing the mesh to
// flat colour — macOS caps at 0.95 and so must this.
TEST(GraphicMeshParamsTest, AlphaRisesWithIntensityButNeverReachesOpaque) {
  const double low = DeriveGraphicMeshParams(1, 0.0, kPaletteSize).blobs[0].alpha;
  const double high = DeriveGraphicMeshParams(1, 1.0, kPaletteSize).blobs[0].alpha;
  EXPECT_DOUBLE_EQ(low, 0.40);
  EXPECT_LT(low, high);
  EXPECT_LE(high, 0.95);

  // Out-of-range intensity is clamped, not extrapolated.
  EXPECT_DOUBLE_EQ(DeriveGraphicMeshParams(1, 5.0, kPaletteSize).blobs[0].alpha,
                   high);
  EXPECT_DOUBLE_EQ(DeriveGraphicMeshParams(1, -3.0, kPaletteSize).blobs[0].alpha,
                   low);
}

// Blob 0 takes colour index 1, not 0: index 0 is the base fill, and repainting
// it over itself would waste the first blob.
TEST(GraphicMeshParamsTest, SkipsTheBaseFillColourAndCyclesTheRest) {
  const auto p = DeriveGraphicMeshParams(1, 0.7, kPaletteSize);
  ASSERT_EQ(p.blobs.size(), 7u);
  EXPECT_EQ(p.blobs[0].palette_index, 1);
  EXPECT_EQ(p.blobs[4].palette_index, 0);  // wraps after the last colour
  for (const auto& blob : p.blobs) {
    EXPECT_GE(blob.palette_index, 0);
    EXPECT_LT(blob.palette_index, kPaletteSize);
  }
}

// ---------------------------------------------------------------------------
// radialGlow
// ---------------------------------------------------------------------------

TEST(RadialGlowParamsTest, AlwaysDrawsExactlyThreeGlows) {
  EXPECT_EQ(DeriveRadialGlowParams(1, 0.7, kPaletteSize).glows.size(), 3u);
  EXPECT_EQ(DeriveRadialGlowParams(1, 0.7, 1).glows.size(), 3u);
}

TEST(RadialGlowParamsTest, IsDeterministicForASeed) {
  const auto a = DeriveRadialGlowParams(9, 0.5, kPaletteSize);
  const auto b = DeriveRadialGlowParams(9, 0.5, kPaletteSize);
  ASSERT_EQ(a.glows.size(), b.glows.size());
  for (size_t i = 0; i < a.glows.size(); ++i) {
    EXPECT_DOUBLE_EQ(a.glows[i].center_x_fraction, b.glows[i].center_x_fraction);
    EXPECT_DOUBLE_EQ(a.glows[i].radius_fraction, b.glows[i].radius_fraction);
  }
}

// Unlike the mesh, glows stay well inside the frame — they are highlights on a
// gradient, not the background itself.
TEST(RadialGlowParamsTest, GlowsStayInsideTheCanvas) {
  const auto p = DeriveRadialGlowParams(4, 0.7, kPaletteSize);
  for (const auto& glow : p.glows) {
    EXPECT_GE(glow.center_x_fraction, 0.15);
    EXPECT_LE(glow.center_x_fraction, 0.85);
    EXPECT_GE(glow.center_y_fraction, 0.15);
    EXPECT_LE(glow.center_y_fraction, 0.85);
    EXPECT_GE(glow.radius_fraction, 0.4);
    EXPECT_LE(glow.radius_fraction, 0.8);
  }
}

// This preset is meant to be the calm one: its glows sit on a full-strength
// gradient, so they are far fainter than the mesh blobs that ARE the picture.
TEST(RadialGlowParamsTest, GlowsAreMuchFainterThanMeshBlobs) {
  const double glow = DeriveRadialGlowParams(1, 1.0, kPaletteSize).glows[0].alpha;
  const double mesh = DeriveGraphicMeshParams(1, 1.0, kPaletteSize).blobs[0].alpha;
  EXPECT_DOUBLE_EQ(DeriveRadialGlowParams(1, 0.0, kPaletteSize).glows[0].alpha,
                   0.10);
  EXPECT_NEAR(glow, 0.38, 1e-9);
  EXPECT_LT(glow, mesh);
}

// macOS walks the palette BACKWARDS from the lightest colour, so the glows are
// the bright end of the ramp. Walking forwards would light the canvas with its
// darkest colours and the preset would look like nothing happened.
TEST(RadialGlowParamsTest, WalksThePaletteBackwardsFromTheLightest) {
  const auto p = DeriveRadialGlowParams(1, 0.7, kPaletteSize);
  ASSERT_EQ(p.glows.size(), 3u);
  EXPECT_EQ(p.glows[0].palette_index, 4);
  EXPECT_EQ(p.glows[1].palette_index, 3);
  EXPECT_EQ(p.glows[2].palette_index, 2);
}

// A degenerate palette must not produce a negative index into the colour array.
TEST(RadialGlowParamsTest, SingleColourPaletteStaysInBounds) {
  const auto p = DeriveRadialGlowParams(1, 0.7, 1);
  for (const auto& glow : p.glows) {
    EXPECT_EQ(glow.palette_index, 0);
  }
}

// Both derivations must tolerate a palette the catalog could never return
// rather than indexing into nothing.
TEST(CanvasPresetParamsTest, EmptyPaletteYieldsNoShapes) {
  EXPECT_TRUE(DeriveGraphicMeshParams(1, 0.7, 0).blobs.empty());
  EXPECT_TRUE(DeriveRadialGlowParams(1, 0.7, 0).glows.empty());
  EXPECT_TRUE(DeriveGraphicMeshParams(1, 0.7, -2).blobs.empty());
  EXPECT_TRUE(DeriveRadialGlowParams(1, 0.7, -2).glows.empty());
}

// The two presets share one RNG but consume it in different amounts, so the
// same seed must NOT place a glow where it places a blob.
TEST(CanvasPresetParamsTest, TheTwoPresetsDoNotProduceTheSameLayout) {
  const auto mesh = DeriveGraphicMeshParams(11, 0.7, kPaletteSize);
  const auto glow = DeriveRadialGlowParams(11, 0.7, kPaletteSize);
  ASSERT_FALSE(mesh.blobs.empty());
  ASSERT_FALSE(glow.glows.empty());
  EXPECT_NE(mesh.blobs[0].center_x_fraction, glow.glows[0].center_x_fraction);
}

}  // namespace
}  // namespace clingfy::capture::background
