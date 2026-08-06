// The camera-composition wire parser. This payload used to be parsed twice --
// once in preview_router (previewSetCameraPlacement, placement drags) and once
// hand-duplicated in export_router (processVideo, editor open + every styling
// change). The drift was real twice over: it hid a missing-chroma bug in the
// 9.7 review, and it left the intro/outro animation keys parsed on the export
// request only, so the inline preview never animated.
//
// bridge_contract_coverage_test checks method NAMES, so it cannot see a field
// read on one path and not the other. These tests cover the single parser both
// paths now share, which is what makes that class of drift unrepresentable.

#include "Bridge/Routers/camera_composition_args.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>

namespace clingfy::bridge {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableValue Key(const char* k) { return EncodableValue(std::string(k)); }

// The full payload CameraCompositionState.toMap() emits.
EncodableMap FullArgs() {
  return EncodableMap{
      {Key("cameraVisible"), EncodableValue(true)},
      {Key("cameraLayoutPreset"), EncodableValue(std::string("overlayTopLeft"))},
      {Key("cameraSizeFactor"), EncodableValue(0.25)},
      {Key("cameraShape"), EncodableValue(std::string("squircle"))},
      {Key("cameraCornerRadius"), EncodableValue(0.3)},
      {Key("cameraContentMode"), EncodableValue(std::string("fill"))},
      {Key("cameraMirror"), EncodableValue(true)},
      {Key("cameraOpacity"), EncodableValue(0.8)},
      {Key("cameraBorderWidth"), EncodableValue(4.0)},
      {Key("cameraBorderColorArgb"),
       EncodableValue(static_cast<std::int64_t>(0xFF00FF00))},
      {Key("cameraShadowPreset"), EncodableValue(2)},
      {Key("cameraChromaKeyEnabled"), EncodableValue(true)},
      {Key("cameraChromaKeyStrength"), EncodableValue(0.55)},
      {Key("cameraChromaKeyColorArgb"),
       EncodableValue(static_cast<std::int64_t>(0xFF00FF00))},
      {Key("cameraIntroPreset"), EncodableValue(std::string("pop"))},
      {Key("cameraOutroPreset"), EncodableValue(std::string("slide"))},
      {Key("cameraIntroDurationMs"), EncodableValue(300)},
      {Key("cameraOutroDurationMs"), EncodableValue(260)},
      {Key("cameraNormalizedCenter"),
       EncodableValue(EncodableMap{{Key("x"), EncodableValue(0.7)},
                                   {Key("y"), EncodableValue(0.9)}})},
  };
}

TEST(ReadCameraComposition, ReadsTheAnimationKeys) {
  // The regression this parser exists for: these four were read by the export
  // request parser but by neither preview path, so the editor showed a static
  // bubble while the exported file animated.
  const auto c = ReadCameraComposition(FullArgs());
  EXPECT_EQ(c.intro_preset, "pop");
  EXPECT_EQ(c.outro_preset, "slide");
  EXPECT_EQ(c.intro_duration_ms, 300);
  EXPECT_EQ(c.outro_duration_ms, 260);
}

TEST(ReadCameraComposition, AnimationDefaultsToNoneNotTheSeedDefaults) {
  // CameraEditorSeed defaults are fade/shrink/220/180 and the Dart defaults
  // match, which makes them tempting fallbacks here. They would be wrong: the
  // export request parser falls back to ""/0, so seeding fade/220 would make a
  // partial payload animate in the PREVIEW but not in the export -- inverting
  // the bug this parser closes.
  const auto c = ReadCameraComposition(EncodableMap{});
  EXPECT_EQ(c.intro_preset, "");
  EXPECT_EQ(c.outro_preset, "");
  EXPECT_EQ(c.intro_duration_ms, 0);
  EXPECT_EQ(c.outro_duration_ms, 0);
}

TEST(ReadCameraComposition, ReadsTheFullStylePayload) {
  const auto c = ReadCameraComposition(FullArgs());
  EXPECT_TRUE(c.visible);
  EXPECT_EQ(c.layout_preset, "overlayTopLeft");
  EXPECT_DOUBLE_EQ(c.size_factor, 0.25);
  EXPECT_EQ(c.shape, "squircle");
  EXPECT_DOUBLE_EQ(c.corner_radius, 0.3);
  EXPECT_EQ(c.content_mode, "fill");
  EXPECT_TRUE(c.mirror);
  EXPECT_DOUBLE_EQ(c.opacity, 0.8);
  EXPECT_DOUBLE_EQ(c.border_width, 4.0);
  EXPECT_TRUE(c.has_border_color);
  EXPECT_EQ(c.border_argb, 0xFF00FF00u);
  EXPECT_EQ(c.shadow_preset, 2);
  EXPECT_TRUE(c.chroma_enabled);
  EXPECT_DOUBLE_EQ(c.chroma_strength, 0.55);
  EXPECT_TRUE(c.has_chroma_color);
}

TEST(ReadCameraComposition, ReadsTheNestedNormalizedCenter) {
  const auto c = ReadCameraComposition(FullArgs());
  EXPECT_TRUE(c.has_center);
  EXPECT_DOUBLE_EQ(c.center_x, 0.7);
  EXPECT_DOUBLE_EQ(c.center_y, 0.9);
}

TEST(ReadCameraComposition, AbsentCenterLeavesPresetPlacement) {
  // has_center false is what lets layout_preset drive placement downstream; a
  // spuriously-present center would override the corner presets everywhere.
  auto args = FullArgs();
  args.erase(Key("cameraNormalizedCenter"));
  const auto c = ReadCameraComposition(args);
  EXPECT_FALSE(c.has_center);
}

TEST(ReadCameraComposition, NullColorsStayAbsentRatherThanBecomingBlack) {
  // Dart sends null (not 0) when no custom colour is set. Parsing that as 0
  // would paint an opaque black border / key on pure black.
  auto args = FullArgs();
  args[Key("cameraBorderColorArgb")] = EncodableValue();
  args[Key("cameraChromaKeyColorArgb")] = EncodableValue();
  const auto c = ReadCameraComposition(args);
  EXPECT_FALSE(c.has_border_color);
  EXPECT_FALSE(c.has_chroma_color);
}

TEST(ReadCameraComposition, AcceptsIntegerEncodedDoubles) {
  // The standard codec ships an integer-valued double as int32/int64. A
  // double-only read would silently fall back on a slider parked at a whole
  // number -- e.g. opacity 1 arriving as int and reading back as the 1.0
  // fallback is invisible, but border width 0 would read as 0.0 either way.
  EncodableMap args{
      {Key("cameraSizeFactor"), EncodableValue(1)},
      {Key("cameraOpacity"), EncodableValue(static_cast<std::int64_t>(0))},
      {Key("cameraIntroDurationMs"), EncodableValue(220.0)},
  };
  const auto c = ReadCameraComposition(args);
  EXPECT_DOUBLE_EQ(c.size_factor, 1.0);
  EXPECT_DOUBLE_EQ(c.opacity, 0.0);
  EXPECT_EQ(c.intro_duration_ms, 220);
}

TEST(ReadCameraComposition, WrongTypedValuesFallBackInsteadOfThrowing) {
  // A malformed payload must soft-fail to defaults; the preview never errors on
  // a styling arg.
  EncodableMap args{
      {Key("cameraVisible"), EncodableValue(std::string("yes"))},
      {Key("cameraOpacity"), EncodableValue(std::string("half"))},
      {Key("cameraIntroPreset"), EncodableValue(7)},
      {Key("cameraNormalizedCenter"), EncodableValue(std::string("nope"))},
  };
  const auto c = ReadCameraComposition(args);
  EXPECT_FALSE(c.visible);
  EXPECT_DOUBLE_EQ(c.opacity, 1.0);
  EXPECT_EQ(c.intro_preset, "");
  EXPECT_FALSE(c.has_center);
}

}  // namespace
}  // namespace clingfy::bridge
