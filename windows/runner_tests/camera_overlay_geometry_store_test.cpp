// Unit tests for the live camera-overlay geometry mapping — the pure
// translation from the Dart wire model (size + OverlayPosition / normalized
// center) to a floating-window rectangle, plus the thread-safe store's
// revision + custom-flag behavior. No Win32 window is created here; the visual
// result is a human smoke check on real hardware.

#include "Capture/Camera/camera_overlay_geometry_store.h"

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

// A canonical 1080p work area with no taskbar inset, DPI 100%.
constexpr int kL = 0, kT = 0, kR = 1920, kB = 1080;
constexpr double kNoScale = 1.0;

CameraOverlayGeometry Preset(double size, int position) {
  CameraOverlayGeometry g;
  g.size = size;
  g.position = position;
  g.use_custom = false;
  return g;
}

TEST(ComputeFloatingRect, DefaultSizeMapsHeightToShortEdgeWithAspect) {
  // Height carries `size`; width follows 16:9.
  const FloatingRect r =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 3));
  EXPECT_EQ(r.height, 220);
  EXPECT_EQ(r.width, 391);  // lround(220 * 16 / 9)
}

TEST(ComputeFloatingRect, BottomRightIsMarginInsetFromBottomRightCorner) {
  const FloatingRect r =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 3));
  const int margin = 1920 * 3 / 100;  // 57
  EXPECT_EQ(r.x, 1920 - r.width - margin);
  EXPECT_EQ(r.y, 1080 - r.height - margin);
}

TEST(ComputeFloatingRect, EachCornerAnchorsCorrectly) {
  const int margin = 1920 * 3 / 100;  // 57
  const int w = 391, h = 220;

  const FloatingRect tl =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 0));
  EXPECT_EQ(tl.x, margin);
  EXPECT_EQ(tl.y, margin);

  const FloatingRect tr =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 1));
  EXPECT_EQ(tr.x, 1920 - w - margin);
  EXPECT_EQ(tr.y, margin);

  const FloatingRect bl =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 2));
  EXPECT_EQ(bl.x, margin);
  EXPECT_EQ(bl.y, 1080 - h - margin);

  const FloatingRect br =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 3));
  EXPECT_EQ(br.x, 1920 - w - margin);
  EXPECT_EQ(br.y, 1080 - h - margin);
}

TEST(ComputeFloatingRect, DpiScaleScalesTheBubble) {
  const FloatingRect r =
      ComputeFloatingRect(kL, kT, kR, kB, /*dpi_scale=*/2.0, Preset(220.0, 3));
  EXPECT_EQ(r.height, 440);            // 220 * 2
  EXPECT_EQ(r.width, 782);             // lround(440 * 16 / 9)
}

TEST(ComputeFloatingRect, SizeClampedToSliderBounds) {
  // Below the 120 floor.
  const FloatingRect small =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(50.0, 3));
  EXPECT_EQ(small.height, 120);
  // Above the 400 ceiling.
  const FloatingRect big =
      ComputeFloatingRect(kL, kT, kR, kB, kNoScale, Preset(1000.0, 3));
  EXPECT_EQ(big.height, 400);
  EXPECT_EQ(big.width, 711);  // lround(400 * 16 / 9)
}

TEST(ComputeFloatingRect, NeverExceedsWorkArea) {
  // A large bubble on a tiny screen must shrink to fit inside the work area.
  const FloatingRect r =
      ComputeFloatingRect(0, 0, 300, 200, kNoScale, Preset(400.0, 3));
  EXPECT_LE(r.width, 300);
  EXPECT_LE(r.height, 200);
  EXPECT_GE(r.x, 0);
  EXPECT_GE(r.y, 0);
  EXPECT_LE(r.x + r.width, 300);
  EXPECT_LE(r.y + r.height, 200);
}

TEST(ComputeFloatingRect, CustomPositionCentersOnNormalizedPoint) {
  CameraOverlayGeometry g;
  g.size = 220.0;
  g.use_custom = true;
  g.normalized_x = 0.5;
  g.normalized_y = 0.5;
  const FloatingRect r = ComputeFloatingRect(kL, kT, kR, kB, kNoScale, g);
  EXPECT_NEAR(r.x + r.width / 2.0, 960.0, 1.0);
  EXPECT_NEAR(r.y + r.height / 2.0, 540.0, 1.0);
}

TEST(ComputeFloatingRect, CustomPositionClampsInsideWorkArea) {
  CameraOverlayGeometry g;
  g.size = 220.0;
  g.use_custom = true;
  g.normalized_x = 1.0;  // hard right edge — half the bubble would spill out.
  g.normalized_y = 1.0;
  const FloatingRect r = ComputeFloatingRect(kL, kT, kR, kB, kNoScale, g);
  EXPECT_LE(r.x + r.width, 1920);
  EXPECT_LE(r.y + r.height, 1080);
  EXPECT_GE(r.x, 0);
  EXPECT_GE(r.y, 0);
}

TEST(ComputeFloatingRect, WorkAreaOffsetIsHonored) {
  // A left-docked taskbar shifts the work area origin; corners follow it.
  const FloatingRect tl =
      ComputeFloatingRect(120, 40, 1920, 1080, kNoScale, Preset(220.0, 0));
  const int margin = (1920 - 120) * 3 / 100;
  EXPECT_EQ(tl.x, 120 + margin);
  EXPECT_EQ(tl.y, 40 + margin);
}

// ---- store ----------------------------------------------------------------

TEST(CameraOverlayGeometryStore, DefaultsMatchDartDefaults) {
  CameraOverlayGeometryStore store;
  const CameraOverlayGeometry g = store.Snapshot();
  EXPECT_DOUBLE_EQ(g.size, 220.0);
  EXPECT_EQ(g.position, 3);  // bottomRight
  EXPECT_FALSE(g.use_custom);
}

TEST(CameraOverlayGeometryStore, SettersBumpRevision) {
  CameraOverlayGeometryStore store;
  const std::uint64_t r0 = store.revision();
  store.SetSize(300.0);
  const std::uint64_t r1 = store.revision();
  store.SetPosition(1);
  const std::uint64_t r2 = store.revision();
  store.SetCustomPosition(0.25, 0.75);
  const std::uint64_t r3 = store.revision();
  EXPECT_GT(r1, r0);
  EXPECT_GT(r2, r1);
  EXPECT_GT(r3, r2);
}

TEST(CameraOverlayGeometryStore, SetSizeIsStoredRaw) {
  CameraOverlayGeometryStore store;
  store.SetSize(333.0);
  EXPECT_DOUBLE_EQ(store.Snapshot().size, 333.0);
}

TEST(CameraOverlayGeometryStore, PresetClearsCustomFlag) {
  CameraOverlayGeometryStore store;
  store.SetCustomPosition(0.2, 0.3);
  EXPECT_TRUE(store.Snapshot().use_custom);
  store.SetPosition(0);
  const CameraOverlayGeometry g = store.Snapshot();
  EXPECT_FALSE(g.use_custom);
  EXPECT_EQ(g.position, 0);
}

TEST(CameraOverlayGeometryStore, CustomPositionSetsFlagAndCenter) {
  CameraOverlayGeometryStore store;
  store.SetCustomPosition(0.25, 0.75);
  const CameraOverlayGeometry g = store.Snapshot();
  EXPECT_TRUE(g.use_custom);
  EXPECT_DOUBLE_EQ(g.normalized_x, 0.25);
  EXPECT_DOUBLE_EQ(g.normalized_y, 0.75);
}

TEST(CameraOverlayGeometryStore, SetCustomPositionReturnsItsRevision) {
  CameraOverlayGeometryStore store;
  const std::uint64_t r1 = store.SetCustomPosition(0.1, 0.2);
  EXPECT_EQ(r1, store.revision());
  const std::uint64_t r2 = store.SetCustomPosition(0.3, 0.4);
  EXPECT_EQ(r2, store.revision());
  EXPECT_GT(r2, r1);
}

TEST(CameraOverlayGeometryStore, AdoptDragRevisionOnlyWhenUncontended) {
  // Clean write-back: the drag's revision directly follows the last-synced one,
  // so it is adopted and the next sync tick self-suppresses.
  EXPECT_EQ(AdoptDragRevision(7, 8), 8u);
  // A platform-thread setter (size slider, settings replay) landed between the
  // overlay's last sync tick and the drag write-back. Adopting revision 9 would
  // jump the seen counter past the setter's revision 8 and silently drop it —
  // the seen value must stay put so the next tick applies both mutations.
  EXPECT_EQ(AdoptDragRevision(7, 9), 7u);
  // First-check sentinel (~0 forces a sync): never adopt across it.
  EXPECT_EQ(AdoptDragRevision(~0ull, 1), ~0ull);
}

// ---- drag write-back inverse ------------------------------------------------

TEST(NormalizedCenterForRect, CenterOfWorkAreaIsHalfHalf) {
  const NormalizedCenter c =
      NormalizedCenterForRect(0, 0, 1920, 1080, FloatingRect{860, 440, 200, 200});
  EXPECT_DOUBLE_EQ(c.x, 0.5);
  EXPECT_DOUBLE_EQ(c.y, 0.5);
}

TEST(NormalizedCenterForRect, HonorsWorkAreaOffset) {
  // Left-docked taskbar: work area starts at x=120. A rect whose center sits at
  // the work-area origin maps to (0,0), not a negative fraction.
  const NormalizedCenter c =
      NormalizedCenterForRect(120, 40, 1920, 1080, FloatingRect{20, -60, 200, 200});
  EXPECT_DOUBLE_EQ(c.x, 0.0);
  EXPECT_DOUBLE_EQ(c.y, 0.0);
}

TEST(NormalizedCenterForRect, ClampsOutOfBoundsCenters) {
  const NormalizedCenter c = NormalizedCenterForRect(
      0, 0, 1920, 1080, FloatingRect{2000, 1200, 100, 100});
  EXPECT_DOUBLE_EQ(c.x, 1.0);
  EXPECT_DOUBLE_EQ(c.y, 1.0);
}

TEST(NormalizedCenterForRect, RoundTripsThroughComputeFloatingRect) {
  // Placing at a custom center then reading the center back must agree within
  // sub-pixel normalized tolerance — this is what keeps a drag from drifting.
  CameraOverlayGeometry g;
  g.size = 220.0;
  g.use_custom = true;
  g.normalized_x = 0.31;
  g.normalized_y = 0.62;
  const FloatingRect r = ComputeFloatingRect(0, 0, 1920, 1080, 1.0, g);
  const NormalizedCenter c = NormalizedCenterForRect(0, 0, 1920, 1080, r);
  EXPECT_NEAR(c.x, 0.31, 0.001);
  EXPECT_NEAR(c.y, 0.62, 0.001);
}

// ---- padded square rect (renderer redesign P4a) ------------------------------

TEST(ComputePaddedSquareFloatingRect, WindowIsContentOutsetByPadding) {
  const FloatingRect content =
      ComputeSquareFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 3));
  const PaddedSquareRect p = ComputePaddedSquareFloatingRect(
      kL, kT, kR, kB, kNoScale, Preset(220.0, 3), 30.0);
  EXPECT_EQ(p.padding_px, 30);
  EXPECT_EQ(p.content_side, content.width);
  EXPECT_EQ(p.window.x, content.x - 30);
  EXPECT_EQ(p.window.y, content.y - 30);
  EXPECT_EQ(p.window.width, content.width + 60);
  EXPECT_EQ(p.window.height, content.height + 60);
}

TEST(ComputePaddedSquareFloatingRect, ContentKeepsTheMarginTheHaloOverhangs) {
  // macOS parity: presets place the panel at margin - effectPadding, i.e. the
  // CONTENT sits at the work-area margin and the halo extends exactly
  // padding px past the margin line (still inside the work area while
  // margin > padding — the true edge overhang is pinned separately below).
  const int margin = 1920 * 3 / 100;
  const PaddedSquareRect p = ComputePaddedSquareFloatingRect(
      kL, kT, kR, kB, kNoScale, Preset(220.0, 3), 30.0);
  EXPECT_EQ(p.window.x + p.padding_px, 1920 - 220 - margin);  // content at margin
  EXPECT_EQ(p.window.x + p.window.width, 1920 - margin + 30);
}

TEST(ComputePaddedSquareFloatingRect, HaloOverhangsTheWorkAreaAtClampedEdge) {
  // Content clamped to the work-area corner (custom 1.0,1.0): the WINDOW must
  // extend past the work-area edge by exactly the padding. A later "fix"
  // clamping the padded window into the work area would pass the margin test
  // above yet silently shift edge-parked content inward by the padding.
  CameraOverlayGeometry g;
  g.size = 220.0;
  g.use_custom = true;
  g.normalized_x = 1.0;
  g.normalized_y = 1.0;
  const PaddedSquareRect p =
      ComputePaddedSquareFloatingRect(kL, kT, kR, kB, kNoScale, g, 30.0);
  EXPECT_EQ(p.window.x + p.window.width, 1920 + 30);
  EXPECT_EQ(p.window.y + p.window.height, 1080 + 30);
}

TEST(ComputePaddedSquareFloatingRect, NegativeOriginWorkAreaIsHandled) {
  // Secondary monitor left of the primary: every coordinate is negative. The
  // padded window must track the content there, not clamp to zero.
  const PaddedSquareRect p = ComputePaddedSquareFloatingRect(
      -1920, 0, 0, 1080, kNoScale, Preset(220.0, 0), 30.0);
  const FloatingRect content = ComputeSquareFloatingRect(
      -1920, 0, 0, 1080, kNoScale, Preset(220.0, 0));
  EXPECT_EQ(p.window.x, content.x - 30);
  EXPECT_EQ(p.window.y, content.y - 30);
  EXPECT_LT(p.window.x, 0);
}

TEST(ComputePaddedSquareFloatingRect, FractionalPaddingCeilsAndNegativeClamps) {
  const PaddedSquareRect frac = ComputePaddedSquareFloatingRect(
      kL, kT, kR, kB, kNoScale, Preset(220.0, 3), 12.3);
  EXPECT_EQ(frac.padding_px, 13);
  const FloatingRect content =
      ComputeSquareFloatingRect(kL, kT, kR, kB, kNoScale, Preset(220.0, 3));
  const PaddedSquareRect none = ComputePaddedSquareFloatingRect(
      kL, kT, kR, kB, kNoScale, Preset(220.0, 3), -5.0);
  EXPECT_EQ(none.padding_px, 0);
  EXPECT_EQ(none.window.x, content.x);
  EXPECT_EQ(none.window.width, content.width);
}

TEST(ComputePaddedSquareFloatingRect, PaddingIsNotDpiScaled) {
  // The painter renders border/shadow/glow in physical px regardless of the
  // monitor scale, so the halo must not be scaled either — only the content
  // side follows DPI.
  const PaddedSquareRect p = ComputePaddedSquareFloatingRect(
      kL, kT, kR, kB, 1.5, Preset(220.0, 3), 30.0);
  EXPECT_EQ(p.content_side, 330);  // 220 * 1.5
  EXPECT_EQ(p.padding_px, 30);     // NOT 45
  EXPECT_EQ(p.window.width, 330 + 60);
}

TEST(ComputePaddedSquareFloatingRect, DragWriteBackStaysPaddingAgnostic) {
  // Uniform padding preserves the center, so NormalizedCenterForRect over the
  // WINDOW rect reproduces the custom center — the drag write-back path needs
  // no padding knowledge.
  CameraOverlayGeometry g;
  g.size = 220.0;
  g.use_custom = true;
  g.normalized_x = 0.31;
  g.normalized_y = 0.62;
  const PaddedSquareRect p =
      ComputePaddedSquareFloatingRect(kL, kT, kR, kB, kNoScale, g, 41.0);
  const NormalizedCenter c = NormalizedCenterForRect(kL, kT, kR, kB, p.window);
  EXPECT_NEAR(c.x, 0.31, 0.001);
  EXPECT_NEAR(c.y, 0.62, 0.001);
}

// ---- halo hit-test split (renderer redesign P4a) ------------------------------

TEST(CameraOverlayPointInContent, ContentIsInsideHaloIsOutside) {
  constexpr int kPad = 30, kSide = 220;
  // Content corners (inclusive at the low edge, exclusive at the high edge).
  EXPECT_TRUE(CameraOverlayPointInContent(kPad, kPad, kPad, kSide));
  EXPECT_TRUE(CameraOverlayPointInContent(kPad + kSide - 1, kPad + kSide - 1,
                                          kPad, kSide));
  EXPECT_FALSE(CameraOverlayPointInContent(kPad - 1, kPad, kPad, kSide));
  EXPECT_FALSE(CameraOverlayPointInContent(kPad, kPad - 1, kPad, kSide));
  EXPECT_FALSE(CameraOverlayPointInContent(kPad + kSide, kPad, kPad, kSide));
  EXPECT_FALSE(CameraOverlayPointInContent(kPad, kPad + kSide, kPad, kSide));
  // Window corner = pure halo.
  EXPECT_FALSE(CameraOverlayPointInContent(0, 0, kPad, kSide));
  // Zero padding degenerates to the whole window being the drag handle.
  EXPECT_TRUE(CameraOverlayPointInContent(0, 0, 0, kSide));
}

// ---- record-stop -> editor seed geometry ------------------------------------

// A 1920x1080 monitor at the virtual-desktop origin with a 48px taskbar, so the
// work area and the captured content rect deliberately DIFFER — that difference
// is the whole point of the conversion and an identity mapping would hide it.
constexpr int kWorkL = 0, kWorkT = 0, kWorkR = 1920, kWorkB = 1032;
constexpr int kFullL = 0, kFullT = 0, kFullR = 1920, kFullB = 1080;

CameraSeedGeometry SeedForDisplayCapture(const CameraOverlayGeometry& g,
                                         double dpi_scale = 1.0) {
  return ResolveCameraSeedGeometry(g, kWorkL, kWorkT, kWorkR, kWorkB, kFullL,
                                   kFullT, kFullR, kFullB, dpi_scale);
}

CameraOverlayGeometry Dragged(double nx, double ny, double size = 220.0) {
  CameraOverlayGeometry g;
  g.size = size;
  g.use_custom = true;
  g.normalized_x = nx;
  g.normalized_y = ny;
  return g;
}

TEST(CameraLayoutPresetForOverlayPosition, MatchesTheMacosMapping) {
  // macOS CameraLayoutPreset.fromOverlayPosition (Models.swift).
  EXPECT_EQ(CameraLayoutPresetForOverlayPosition(0), "overlayTopLeft");
  EXPECT_EQ(CameraLayoutPresetForOverlayPosition(1), "overlayTopRight");
  EXPECT_EQ(CameraLayoutPresetForOverlayPosition(2), "overlayBottomLeft");
  EXPECT_EQ(CameraLayoutPresetForOverlayPosition(3), "overlayBottomRight");
  // Anything else falls back to bottom-right, like the Swift `default:` arm.
  EXPECT_EQ(CameraLayoutPresetForOverlayPosition(-1), "overlayBottomRight");
  EXPECT_EQ(CameraLayoutPresetForOverlayPosition(99), "overlayBottomRight");
}

TEST(ResolveCameraSeedGeometry, PresetPlacementEmitsNoCenter) {
  // The center must stay absent for a preset placement: downstream a present
  // center OVERRIDES layout_preset, so emitting one would defeat the corners.
  const CameraSeedGeometry seed = SeedForDisplayCapture(Preset(220.0, 0));
  EXPECT_EQ(seed.layout_preset, "overlayTopLeft");
  EXPECT_FALSE(seed.normalized_center_x.has_value());
  EXPECT_FALSE(seed.normalized_center_y.has_value());
}

TEST(ResolveCameraSeedGeometry, DraggedCenterRebasesWorkAreaOntoContent) {
  // Bubble centered in the work area: x is unchanged (the work area and the
  // monitor share their width), but y is NOT — the work area is 1032 tall
  // inside a 1080 capture, so the true center sits at 516/1080 = 0.4778 from
  // the top. Emitted y-UP, so 1 - 0.4778.
  const CameraSeedGeometry seed = SeedForDisplayCapture(Dragged(0.5, 0.5));
  ASSERT_TRUE(seed.normalized_center_x.has_value());
  ASSERT_TRUE(seed.normalized_center_y.has_value());
  EXPECT_NEAR(*seed.normalized_center_x, 0.5, 0.0001);
  EXPECT_NEAR(*seed.normalized_center_y, 1.0 - (516.0 / 1080.0), 0.0001);
}

TEST(ResolveCameraSeedGeometry, EmitsTheCenterYUp) {
  // Top of the work area -> near the TOP of the capture -> y-UP value near 1.
  const CameraSeedGeometry top = SeedForDisplayCapture(Dragged(0.5, 0.0));
  ASSERT_TRUE(top.normalized_center_y.has_value());
  EXPECT_NEAR(*top.normalized_center_y, 1.0, 0.0001);

  // Bottom of the work area -> 1032/1080 down the capture -> 1 - 0.9556.
  const CameraSeedGeometry bottom = SeedForDisplayCapture(Dragged(0.5, 1.0));
  ASSERT_TRUE(bottom.normalized_center_y.has_value());
  EXPECT_NEAR(*bottom.normalized_center_y, 1.0 - (1032.0 / 1080.0), 0.0001);

  // The whole point: dragging DOWN must lower the emitted value.
  EXPECT_LT(*bottom.normalized_center_y, *top.normalized_center_y);
}

TEST(ResolveCameraSeedGeometry, AreaCaptureRebasesAgainstTheCropBox) {
  // A 960x540 crop whose top-left sits at (480, 270) on the monitor. A bubble
  // centered in the work area lands at absolute (960, 516), which is the crop's
  // horizontal center and (516-270)/540 = 0.4556 down it.
  const CameraSeedGeometry seed =
      ResolveCameraSeedGeometry(Dragged(0.5, 0.5), kWorkL, kWorkT, kWorkR,
                                kWorkB, 480, 270, 1440, 810, 1.0);
  ASSERT_TRUE(seed.normalized_center_x.has_value());
  EXPECT_NEAR(*seed.normalized_center_x, 0.5, 0.0001);
  EXPECT_NEAR(*seed.normalized_center_y, 1.0 - ((516.0 - 270.0) / 540.0),
              0.0001);
}

TEST(ResolveCameraSeedGeometry, CenterOutsideTheCapturedAreaClamps) {
  // Bubble dragged to the far left of the work area, but the capture is a crop
  // that starts at x=480 — the bubble was never in frame. Clamp, do not emit a
  // negative fraction.
  const CameraSeedGeometry seed =
      ResolveCameraSeedGeometry(Dragged(0.0, 0.0), kWorkL, kWorkT, kWorkR,
                                kWorkB, 480, 270, 1440, 810, 1.0);
  ASSERT_TRUE(seed.normalized_center_x.has_value());
  EXPECT_DOUBLE_EQ(*seed.normalized_center_x, 0.0);
  EXPECT_DOUBLE_EQ(*seed.normalized_center_y, 1.0);  // y-UP: top of frame
}

TEST(ResolveCameraSeedGeometry, SizeFactorIsTheShortEdgeFraction) {
  // 220 logical px on a 1080-short-edge capture at 100%.
  const CameraSeedGeometry seed = SeedForDisplayCapture(Preset(220.0, 3));
  EXPECT_NEAR(seed.size_factor, 220.0 / 1080.0, 0.0001);
}

TEST(ResolveCameraSeedGeometry, SizeFactorScalesWithTheRecordedMonitorDpi) {
  // The store's size is LOGICAL px but the capture is PHYSICAL px: at 150% a
  // 220pt bubble is 330 physical px on a 1620-tall capture, which is the SAME
  // fraction as the 100% case. Dividing the raw logical size instead would
  // shrink the seeded bubble by a third.
  const CameraSeedGeometry seed = ResolveCameraSeedGeometry(
      Preset(220.0, 3), 0, 0, 2880, 1548, 0, 0, 2880, 1620, 1.5);
  EXPECT_NEAR(seed.size_factor, 330.0 / 1620.0, 0.0001);
  EXPECT_NEAR(seed.size_factor, 220.0 / 1080.0, 0.0001);  // scale-invariant
}

TEST(ResolveCameraSeedGeometry, SizeFactorClampedToTheEditorBand) {
  // A 400px bubble on a tiny capture would exceed the 0.45 ceiling.
  const CameraSeedGeometry big = ResolveCameraSeedGeometry(
      Preset(400.0, 3), 0, 0, 800, 600, 0, 0, 800, 600, 1.0);
  EXPECT_NEAR(big.size_factor, 0.45, 0.0001);
  // A 120px bubble on a 4K capture would fall under the 0.08 floor.
  const CameraSeedGeometry small = ResolveCameraSeedGeometry(
      Preset(120.0, 3), 0, 0, 3840, 2160, 0, 0, 3840, 2160, 1.0);
  EXPECT_NEAR(small.size_factor, 0.08, 0.0001);
}

TEST(ResolveCameraSeedGeometry, DegenerateContentRectFallsBackToDefaults) {
  // Target-loss before the first frame: no content rect. Still hand the editor
  // a usable corner + baseline size rather than a divide-by-zero.
  const CameraSeedGeometry seed = ResolveCameraSeedGeometry(
      Dragged(0.25, 0.25), kWorkL, kWorkT, kWorkR, kWorkB, 0, 0, 0, 0, 1.0);
  EXPECT_EQ(seed.layout_preset, "overlayBottomRight");
  EXPECT_DOUBLE_EQ(seed.size_factor, 0.18);
  EXPECT_FALSE(seed.normalized_center_x.has_value());
}

TEST(ResolveCameraSeedGeometry, DegenerateWorkAreaKeepsSizeButDropsTheCenter) {
  // The content rect is usable (so the size factor is real) but the work area
  // probe failed, so the drag cannot be de-normalized. Fall back to the preset.
  const CameraSeedGeometry seed = ResolveCameraSeedGeometry(
      Dragged(0.25, 0.25), 0, 0, 0, 0, kFullL, kFullT, kFullR, kFullB, 1.0);
  EXPECT_NEAR(seed.size_factor, 220.0 / 1080.0, 0.0001);
  EXPECT_FALSE(seed.normalized_center_x.has_value());
}

TEST(ResolveCameraSeedGeometry, PresetSurvivesADragSoTheEditorCanFallBack) {
  // A dragged bubble still carries its last preset: the editor restores it if
  // the user clears the manual position, and ResolveCameraSlideEdge reads it.
  CameraOverlayGeometry g = Dragged(0.2, 0.3);
  g.position = 1;
  const CameraSeedGeometry seed = SeedForDisplayCapture(g);
  EXPECT_EQ(seed.layout_preset, "overlayTopRight");
  EXPECT_TRUE(seed.normalized_center_x.has_value());
}

}  // namespace
}  // namespace clingfy::capture
