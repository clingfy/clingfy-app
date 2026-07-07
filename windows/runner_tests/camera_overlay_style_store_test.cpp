// Unit tests for the live camera-overlay style mapping — the pure translation
// from the Dart wire model (OverlayShape / OverlayShadow / OverlayBorder) to the
// shared CameraBubblePainter::Style. No D2D device is touched here; the visual
// result is a human smoke check on real hardware.

#include "Capture/Camera/camera_overlay_style_store.h"

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

TEST(OverlayShapeToPainterShape, MapsSupportedShapesOneToOne) {
  EXPECT_EQ(OverlayShapeToPainterShape(0), "circle");
  EXPECT_EQ(OverlayShapeToPainterShape(1), "roundedRect");
  EXPECT_EQ(OverlayShapeToPainterShape(2), "square");
  EXPECT_EQ(OverlayShapeToPainterShape(5), "squircle");
}

TEST(OverlayShapeToPainterShape, UnsupportedShapesFallBack) {
  // hexagon(3) and star(4) have no painter geometry; they degrade to the
  // nearest supported silhouette rather than rendering nothing.
  EXPECT_EQ(OverlayShapeToPainterShape(3), "squircle");  // hexagon
  EXPECT_EQ(OverlayShapeToPainterShape(4), "circle");    // star
}

TEST(OverlayShapeToPainterShape, UnknownWireDefaultsToSquircle) {
  EXPECT_EQ(OverlayShapeToPainterShape(99), "squircle");
  EXPECT_EQ(OverlayShapeToPainterShape(-1), "squircle");
}

TEST(ResolveOverlayBubbleStyle, DefaultsAreAPlainCoverBubble) {
  const ResolvedBubbleStyle r = ResolveOverlayBubbleStyle({});
  EXPECT_EQ(r.shape, "squircle");
  EXPECT_EQ(r.content_mode, "fill");
  EXPECT_DOUBLE_EQ(r.corner_radius, 0.0);
  EXPECT_DOUBLE_EQ(r.style.opacity, 1.0);
  EXPECT_FALSE(r.style.mirror);
  EXPECT_FALSE(r.style.has_border_color);
  EXPECT_DOUBLE_EQ(r.style.border_width, 0.0);
  EXPECT_EQ(r.style.shadow_preset, 0);
  EXPECT_FALSE(r.style.chroma_enabled);
}

TEST(ResolveOverlayBubbleStyle, BorderOnlyWhenPresetSelectedAndWidthPositive) {
  CameraOverlayLiveStyle s;
  s.border_index = 1;  // OverlayBorder.white
  s.border_width = 4.0;
  s.border_argb = 0xFFFFFFFF;
  const ResolvedBubbleStyle r = ResolveOverlayBubbleStyle(s);
  EXPECT_TRUE(r.style.has_border_color);
  EXPECT_DOUBLE_EQ(r.style.border_width, 4.0);
  EXPECT_EQ(r.style.border_argb, 0xFFFFFFFFu);
}

TEST(ResolveOverlayBubbleStyle, BorderNoneSuppressesBorderEvenWithWidth) {
  CameraOverlayLiveStyle s;
  s.border_index = 0;  // OverlayBorder.none
  s.border_width = 8.0;
  s.border_argb = 0xFF00FF00;
  const ResolvedBubbleStyle r = ResolveOverlayBubbleStyle(s);
  EXPECT_FALSE(r.style.has_border_color);
  EXPECT_DOUBLE_EQ(r.style.border_width, 0.0);
}

TEST(ResolveOverlayBubbleStyle, ClampsOpacityCornerRadiusAndChromaStrength) {
  CameraOverlayLiveStyle s;
  s.opacity = 1.7;
  s.roundness = 0.9;
  s.chroma_enabled = true;
  s.chroma_strength = -0.3;
  const ResolvedBubbleStyle r = ResolveOverlayBubbleStyle(s);
  EXPECT_DOUBLE_EQ(r.style.opacity, 1.0);
  EXPECT_DOUBLE_EQ(r.corner_radius, 0.5);
  EXPECT_TRUE(r.style.chroma_enabled);
  EXPECT_DOUBLE_EQ(r.style.chroma_strength, 0.0);
  EXPECT_TRUE(r.style.has_chroma_color);
}

TEST(ResolveOverlayBubbleStyle, ShadowPresetPassesThroughClamped) {
  CameraOverlayLiveStyle s;
  s.shadow_index = 2;  // OverlayShadow.medium
  EXPECT_EQ(ResolveOverlayBubbleStyle(s).style.shadow_preset, 2);
  s.shadow_index = 99;
  EXPECT_EQ(ResolveOverlayBubbleStyle(s).style.shadow_preset, 3);
  s.shadow_index = -5;
  EXPECT_EQ(ResolveOverlayBubbleStyle(s).style.shadow_preset, 0);
}

TEST(CameraOverlayInscribedSquare, LandscapeWindowCentersASquareOfHeight) {
  // 16:9 floating window: the compact-shape square is height x height, centered
  // horizontally — NOT the full window (that would render a rectangle).
  const InscribedSquare sq = CameraOverlayInscribedSquare(400, 225);
  EXPECT_EQ(sq.side, 225);
  EXPECT_EQ(sq.x, (400 - 225) / 2);
  EXPECT_EQ(sq.y, 0);
  // Provably narrower than the window, so the silhouette differs from a rect.
  EXPECT_LT(sq.side, 400);
}

TEST(CameraOverlayInscribedSquare, PortraitWindowCentersASquareOfWidth) {
  const InscribedSquare sq = CameraOverlayInscribedSquare(120, 300);
  EXPECT_EQ(sq.side, 120);
  EXPECT_EQ(sq.x, 0);
  EXPECT_EQ(sq.y, (300 - 120) / 2);
}

TEST(CameraOverlayInscribedSquare, SquareWindowIsTheWholeBox) {
  const InscribedSquare sq = CameraOverlayInscribedSquare(200, 200);
  EXPECT_EQ(sq.side, 200);
  EXPECT_EQ(sq.x, 0);
  EXPECT_EQ(sq.y, 0);
}

TEST(CameraOverlayStyleStore, SettersMutateSnapshotAndBumpRevision) {
  CameraOverlayStyleStore store;  // isolated instance, not the singleton.
  const std::uint64_t r0 = store.revision();

  store.SetShape(0);
  store.SetRoundness(0.3);
  store.SetOpacity(0.5);
  store.SetShadow(2);
  store.SetBorder(1);
  store.SetBorderWidth(6.0);
  store.SetBorderColor(0xFF112233);
  store.SetMirror(true);
  store.SetChromaEnabled(true);
  store.SetChromaStrength(0.7);
  store.SetChromaColor(0xFF00AA00);

  const CameraOverlayLiveStyle s = store.Snapshot();
  EXPECT_EQ(s.shape_wire, 0);
  EXPECT_DOUBLE_EQ(s.roundness, 0.3);
  EXPECT_DOUBLE_EQ(s.opacity, 0.5);
  EXPECT_EQ(s.shadow_index, 2);
  EXPECT_EQ(s.border_index, 1);
  EXPECT_DOUBLE_EQ(s.border_width, 6.0);
  EXPECT_EQ(s.border_argb, 0xFF112233u);
  EXPECT_TRUE(s.mirror);
  EXPECT_TRUE(s.chroma_enabled);
  EXPECT_DOUBLE_EQ(s.chroma_strength, 0.7);
  EXPECT_EQ(s.chroma_argb, 0xFF00AA00u);

  // Revision advanced once per mutation (11 setters above).
  EXPECT_EQ(store.revision(), r0 + 11);
}


// ---- glow-when-recording (live-only ring) -----------------------------------

TEST(CameraOverlayStyleStore, GlowDefaultsMatchDartDefaults) {
  CameraOverlayStyleStore store;
  const CameraOverlayLiveStyle s = store.Snapshot();
  EXPECT_FALSE(s.glow_enabled);  // Dart pre-gates on recording state.
  EXPECT_DOUBLE_EQ(s.glow_strength, 0.70);
}

TEST(CameraOverlayStyleStore, GlowSettersStoreAndBumpRevision) {
  CameraOverlayStyleStore store;
  const std::uint64_t r0 = store.revision();
  store.SetGlowEnabled(true);
  store.SetGlowStrength(0.35);
  const CameraOverlayLiveStyle s = store.Snapshot();
  EXPECT_TRUE(s.glow_enabled);
  EXPECT_DOUBLE_EQ(s.glow_strength, 0.35);
  EXPECT_EQ(store.revision(), r0 + 2);
}

TEST(CameraOverlayStyleStore, GlowStrengthClampedToWireRange) {
  CameraOverlayStyleStore store;
  store.SetGlowStrength(0.0);  // below the 0.10 floor
  EXPECT_DOUBLE_EQ(store.Snapshot().glow_strength, 0.10);
  store.SetGlowStrength(5.0);  // above the 1.00 ceiling
  EXPECT_DOUBLE_EQ(store.Snapshot().glow_strength, 1.00);
}

TEST(ResolveOverlayBubbleStyle, GlowNeverLeaksIntoThePainterStyle) {
  // The glow ring is live-only (macOS never exports it); the painter Style has
  // no glow field, and resolving a glowing snapshot must not disturb ANY of the
  // shared fields the exporter consumes. Every ResolvedBubbleStyle field is
  // compared: a glow ring naively implemented as a border stroke (the most
  // plausible leak vector) would be baked into exports by the shared painter,
  // and a partial comparison would let that pass.
  CameraOverlayLiveStyle s;
  s.glow_enabled = true;
  s.glow_strength = 1.0;
  const ResolvedBubbleStyle with_glow = ResolveOverlayBubbleStyle(s);
  const ResolvedBubbleStyle without = ResolveOverlayBubbleStyle({});
  EXPECT_EQ(with_glow.shape, without.shape);
  EXPECT_DOUBLE_EQ(with_glow.corner_radius, without.corner_radius);
  EXPECT_EQ(with_glow.content_mode, without.content_mode);
  EXPECT_EQ(with_glow.style.mirror, without.style.mirror);
  EXPECT_DOUBLE_EQ(with_glow.style.opacity, without.style.opacity);
  EXPECT_DOUBLE_EQ(with_glow.style.border_width, without.style.border_width);
  EXPECT_EQ(with_glow.style.has_border_color, without.style.has_border_color);
  EXPECT_EQ(with_glow.style.border_argb, without.style.border_argb);
  EXPECT_EQ(with_glow.style.shadow_preset, without.style.shadow_preset);
  EXPECT_EQ(with_glow.style.chroma_enabled, without.style.chroma_enabled);
  EXPECT_DOUBLE_EQ(with_glow.style.chroma_strength,
                   without.style.chroma_strength);
  EXPECT_EQ(with_glow.style.has_chroma_color, without.style.has_chroma_color);
  EXPECT_EQ(with_glow.style.chroma_argb, without.style.chroma_argb);
}

}  // namespace
}  // namespace clingfy::capture
