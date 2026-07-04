// Tests for the shared colorGrade wire parser (editing port, color).
// Mirrors the macOS RunnerTests ColorGradeTests fromFlutter coverage — the
// two platforms parse the same Dart `ColorGrade.toMap()` payload and must
// agree on every default and coercion.

#include "Bridge/Routers/color_grade_args.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>

namespace clingfy::bridge {
namespace {

using capture::export_::color::ColorGrade;

flutter::EncodableValue Key(const char* k) {
  return flutter::EncodableValue(std::string(k));
}

TEST(ColorGradeArgsTest, ParsesAllFields) {
  flutter::EncodableMap map;
  map[Key("autoEnabled")] = flutter::EncodableValue(true);
  map[Key("exposure")] = flutter::EncodableValue(0.2);
  map[Key("contrast")] = flutter::EncodableValue(-0.1);
  map[Key("saturation")] = flutter::EncodableValue(0.3);
  map[Key("temperature")] = flutter::EncodableValue(0.05);
  map[Key("tint")] = flutter::EncodableValue(-0.02);
  const flutter::EncodableValue value(map);

  const ColorGrade grade = ParseColorGrade(&value);
  EXPECT_TRUE(grade.auto_enabled);
  EXPECT_DOUBLE_EQ(grade.exposure, 0.2);
  EXPECT_DOUBLE_EQ(grade.contrast, -0.1);
  EXPECT_DOUBLE_EQ(grade.saturation, 0.3);
  EXPECT_DOUBLE_EQ(grade.temperature, 0.05);
  EXPECT_DOUBLE_EQ(grade.tint, -0.02);
  EXPECT_FALSE(grade.IsIdentity());
}

TEST(ColorGradeArgsTest, NullAndNonMapYieldIdentity) {
  EXPECT_TRUE(ParseColorGrade(nullptr).IsIdentity());
  const flutter::EncodableValue not_a_map(std::string("nope"));
  EXPECT_TRUE(ParseColorGrade(&not_a_map).IsIdentity());
  const flutter::EncodableValue null_value;
  EXPECT_TRUE(ParseColorGrade(&null_value).IsIdentity());
}

TEST(ColorGradeArgsTest, MissingKeysDefaultToZeroAndFalse) {
  flutter::EncodableMap map;
  map[Key("exposure")] = flutter::EncodableValue(0.5);
  const flutter::EncodableValue value(map);
  const ColorGrade grade = ParseColorGrade(&value);
  EXPECT_DOUBLE_EQ(grade.exposure, 0.5);
  EXPECT_DOUBLE_EQ(grade.contrast, 0.0);
  EXPECT_DOUBLE_EQ(grade.saturation, 0.0);
  EXPECT_DOUBLE_EQ(grade.temperature, 0.0);
  EXPECT_DOUBLE_EQ(grade.tint, 0.0);
  EXPECT_FALSE(grade.auto_enabled);
  EXPECT_FALSE(grade.IsIdentity());
}

TEST(ColorGradeArgsTest, CoercesIntsLikeMacosNumberHelper) {
  flutter::EncodableMap map;
  // Dart may send 0 as an int over the channel; wider values arrive as i64.
  map[Key("exposure")] = flutter::EncodableValue(std::int32_t{1});
  map[Key("contrast")] = flutter::EncodableValue(std::int64_t{-1});
  // Wrong-typed values coerce to 0, not an error (macOS parity).
  map[Key("saturation")] = flutter::EncodableValue(std::string("0.9"));
  map[Key("tint")] = flutter::EncodableValue(true);
  const flutter::EncodableValue value(map);

  const ColorGrade grade = ParseColorGrade(&value);
  EXPECT_DOUBLE_EQ(grade.exposure, 1.0);
  EXPECT_DOUBLE_EQ(grade.contrast, -1.0);
  EXPECT_DOUBLE_EQ(grade.saturation, 0.0);
  EXPECT_DOUBLE_EQ(grade.tint, 0.0);
}

TEST(ColorGradeArgsTest, ReadColorGradeArgFindsNestedMap) {
  flutter::EncodableMap grade_map;
  grade_map[Key("saturation")] = flutter::EncodableValue(-1.0);
  flutter::EncodableMap args;
  args[Key("projectPath")] = flutter::EncodableValue(std::string("x"));
  args[Key("colorGrade")] = flutter::EncodableValue(grade_map);

  const ColorGrade grade = ReadColorGradeArg(args);
  EXPECT_DOUBLE_EQ(grade.saturation, -1.0);
  EXPECT_FALSE(grade.IsIdentity());

  // Missing key → identity.
  flutter::EncodableMap bare;
  EXPECT_TRUE(ReadColorGradeArg(bare).IsIdentity());
}

// autoEnabled=true with zero values parses as IDENTITY — the Swift-parity
// trap: auto-enhance that computed all-zero adjustments must not force the
// render path.
TEST(ColorGradeArgsTest, AutoEnabledAloneStaysIdentity) {
  flutter::EncodableMap map;
  map[Key("autoEnabled")] = flutter::EncodableValue(true);
  const flutter::EncodableValue value(map);
  const ColorGrade grade = ParseColorGrade(&value);
  EXPECT_TRUE(grade.auto_enabled);
  EXPECT_TRUE(grade.IsIdentity());
}

}  // namespace
}  // namespace clingfy::bridge
