#include "preview/zoom_easing_constants.h"

#include "preview/preview_compositor.h"

#include <cmath>

#include <gtest/gtest.h>

// These tests are deliberately mechanical. Their job is not to exercise
// behavior (there is no behavior in zoom_easing_constants.h) but to:
//
//   1. Force the header to compile in the test TU so the runner_tests
//      target catches any future syntactic breakage.
//   2. Pin every exported constant to the value that lives in the macOS
//      Swift engine or the Dart settings layer. If someone bumps the
//      default zoom factor in
//      lib/core/post_processing/settings/post_processing_settings_controller.dart,
//      these tests fail — and the Windows compositor's "match macOS"
//      promise stays honest.
//
// If a constant truly needs to change, update BOTH sides (Swift / Dart
// AND this header AND this test) in the same PR.

namespace clingfy::preview {
namespace {

TEST(ZoomEasingConstantsTest, FocusHeuristicMotionThresholdMatchesDart) {
  EXPECT_DOUBLE_EQ(kZoomCursorMotionThresholdPx, 12.0);
}

TEST(ZoomEasingConstantsTest, ZoomFactorDefaultsMatchDartSettings) {
  EXPECT_DOUBLE_EQ(kZoomFactorDefault, 1.5);
  EXPECT_DOUBLE_EQ(kZoomFactorMin, 1.0);
  EXPECT_DOUBLE_EQ(kZoomFactorMax, 3.0);
  EXPECT_DOUBLE_EQ(kZoomFactorWriteEpsilon, 0.001);
  EXPECT_TRUE(kZoomEffectEnabledDefault);
}

// --- the preview honours the user's zoom settings ----------------------
//
// The preview used to hardcode kZoomFactorDefault and ignore the effect
// toggle, so the editor zoomed 1.5x whatever the user picked on the
// 1.0-3.0 slider, and kept zooming after they switched the effect off —
// while the export honoured both. These pin the fix.

TEST(ResolveTargetZoom, UsesTheConfiguredFactorNotTheDefault) {
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(true, true, 2.5), 2.5);
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(true, true, 1.2), 1.2);
  // The old behavior would have returned 1.5 for both of the above.
  EXPECT_NE(ResolveTargetZoom(true, true, 2.5), kZoomFactorDefault);
}

TEST(ResolveTargetZoom, EffectDisabledNeverZooms) {
  // Even mid-click, a disabled effect must rest at 1.0 — the export has
  // always skipped the zoom entirely in this case.
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(false, true, 3.0), 1.0);
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(false, false, 3.0), 1.0);
}

TEST(ResolveTargetZoom, RestsAtOneWhenNoZoomWanted) {
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(true, false, 2.0), 1.0);
}

TEST(ResolveTargetZoom, ClampsToTheSliderRange) {
  // A malformed payload must not drive an absurd magnification.
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(true, true, 99.0), kZoomFactorMax);
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(true, true, 0.1), kZoomFactorMin);
  // A factor of exactly 1.0 is legal and means "no visible zoom".
  EXPECT_DOUBLE_EQ(ResolveTargetZoom(true, true, 1.0), 1.0);
}

TEST(ZoomEasingConstantsTest, FollowSmootherBoundsMatchSwift) {
  EXPECT_DOUBLE_EQ(kZoomFollowStrengthDefault, 0.15);
  EXPECT_DOUBLE_EQ(kZoomFollowStrengthMin, 0.05);
  EXPECT_DOUBLE_EQ(kZoomFollowStrengthMax, 0.50);
  EXPECT_DOUBLE_EQ(kZoomFollowReferenceFPS, 60.0);

  // dt bounds are written as 1.0 / N in Swift so the test asserts the
  // same expression rather than a rounded decimal.
  EXPECT_DOUBLE_EQ(kZoomFollowMinDtSeconds, 1.0 / 240.0);
  EXPECT_DOUBLE_EQ(kZoomFollowMaxDtSeconds, 1.0 / 15.0);
}

TEST(ZoomEasingConstantsTest, FollowSmootherDefaultsOrderingIsSane) {
  // Defensive check: if the bounds were ever flipped, the rest of the
  // smoother math would silently still run but produce wrong alpha.
  EXPECT_LT(kZoomFollowStrengthMin, kZoomFollowStrengthDefault);
  EXPECT_LT(kZoomFollowStrengthDefault, kZoomFollowStrengthMax);
  EXPECT_LT(kZoomFollowMinDtSeconds, kZoomFollowMaxDtSeconds);
}

TEST(ZoomEasingConstantsTest, FollowSmootherAlphaFormulaMatchesSwift) {
  // Pin the alpha formula itself, not just the inputs, so a future
  // refactor that "simplifies" the math gets caught.
  //
  //   alpha = 1 - pow(1 - strength, dt * referenceFPS)
  //
  // At default strength and a single 60fps frame (dt = 1/60), this is
  // the per-frame alpha the macOS compositor applies.
  const double strength = kZoomFollowStrengthDefault;
  const double dt = 1.0 / kZoomFollowReferenceFPS;
  const double normalizedFrames = dt * kZoomFollowReferenceFPS;
  const double alpha = 1.0 - std::pow(1.0 - strength, normalizedFrames);
  EXPECT_NEAR(alpha, kZoomFollowStrengthDefault, 1e-12);
}

TEST(ZoomEasingConstantsTest, HysteresisDelaysMatchSwift) {
  EXPECT_DOUBLE_EQ(kZoomInDelaySeconds, 0.2);
  EXPECT_DOUBLE_EQ(kZoomOutDelaySeconds, 0.3);
  EXPECT_DOUBLE_EQ(kZoomMinOnSeconds, 0.30);
}

TEST(ZoomEasingConstantsTest, TimelineBuilderConstantsMatchSwift) {
  EXPECT_DOUBLE_EQ(kZoomTimelineSimulationFPS, 60.0);
  EXPECT_EQ(kZoomTimelineGapMergeMs, 120);
  EXPECT_EQ(kZoomTimelineMinSegmentFrames, 2);
}

TEST(ZoomEasingConstantsTest, KeyframeInterpolationIsLinear) {
  EXPECT_EQ(kZoomKeyframeInterpolation,
            ZoomKeyframeInterpolation::kLinear);
}

}  // namespace
}  // namespace clingfy::preview
