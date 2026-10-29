// The one wire parser for a zoom segment's focus (Bridge/Routers/
// zoom_focus_args.h). Pins the shapes Dart sends on both paths: ZoomSegment
// .toMap for saveManualZoomSegments and the previewSetZoomSegments map.

#include "Bridge/Routers/zoom_focus_args.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>

namespace clingfy::bridge {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableMap Point(EncodableValue dx, EncodableValue dy) {
  return EncodableMap{{EncodableValue("dx"), std::move(dx)},
                      {EncodableValue("dy"), std::move(dy)}};
}

TEST(ZoomFocusArgsTest, AFixedTargetWithAPointIsPinned) {
  const EncodableMap segment{
      {EncodableValue("focusMode"), EncodableValue(std::string("fixedTarget"))},
      {EncodableValue("fixedTarget"),
       EncodableValue(Point(EncodableValue(0.25), EncodableValue(0.75)))},
  };
  const ZoomFocusArgs args = ReadZoomFocusArgs(segment);
  EXPECT_EQ(args.focus_mode, "fixedTarget");
  EXPECT_TRUE(args.has_point);
  EXPECT_TRUE(args.fixed_target());
  EXPECT_DOUBLE_EQ(args.x, 0.25);
  EXPECT_DOUBLE_EQ(args.y, 0.75);
}

TEST(ZoomFocusArgsTest, IntegerCoordinatesAreAccepted) {
  // The codec sends a whole-number double from Dart as an int.
  const EncodableMap segment{
      {EncodableValue("focusMode"), EncodableValue(std::string("fixedTarget"))},
      {EncodableValue("fixedTarget"),
       EncodableValue(Point(EncodableValue(std::int32_t{1}),
                            EncodableValue(std::int64_t{0})))},
  };
  const ZoomFocusArgs args = ReadZoomFocusArgs(segment);
  EXPECT_TRUE(args.fixed_target());
  EXPECT_DOUBLE_EQ(args.x, 1.0);
  EXPECT_DOUBLE_EQ(args.y, 0.0);
}

TEST(ZoomFocusArgsTest, CoordinatesAreClampedToTheFrame) {
  const EncodableMap segment{
      {EncodableValue("focusMode"), EncodableValue(std::string("fixedTarget"))},
      {EncodableValue("fixedTarget"),
       EncodableValue(Point(EncodableValue(-0.5), EncodableValue(3.0)))},
  };
  const ZoomFocusArgs args = ReadZoomFocusArgs(segment);
  EXPECT_DOUBLE_EQ(args.x, 0.0);
  EXPECT_DOUBLE_EQ(args.y, 1.0);
}

TEST(ZoomFocusArgsTest, FollowCursorIsNotPinnedEvenWithAPoint) {
  const EncodableMap segment{
      {EncodableValue("focusMode"),
       EncodableValue(std::string("followCursor"))},
      {EncodableValue("fixedTarget"),
       EncodableValue(Point(EncodableValue(0.1), EncodableValue(0.1)))},
  };
  const ZoomFocusArgs args = ReadZoomFocusArgs(segment);
  EXPECT_EQ(args.focus_mode, "followCursor");
  EXPECT_FALSE(args.fixed_target());
}

TEST(ZoomFocusArgsTest, OldPayloadsWithoutFocusKeysAreNotPinned) {
  const EncodableMap segment{
      {EncodableValue("startMs"), EncodableValue(0)},
      {EncodableValue("endMs"), EncodableValue(1000)},
  };
  const ZoomFocusArgs args = ReadZoomFocusArgs(segment);
  EXPECT_TRUE(args.focus_mode.empty());
  EXPECT_FALSE(args.has_point);
  EXPECT_FALSE(args.fixed_target());
}

TEST(ZoomFocusArgsTest, AHalfOrNonNumericPointIsNoPoint) {
  for (const EncodableMap& point :
       {EncodableMap{{EncodableValue("dx"), EncodableValue(0.5)}},
        Point(EncodableValue(std::string("0.5")), EncodableValue(0.5))}) {
    const EncodableMap segment{
        {EncodableValue("focusMode"),
         EncodableValue(std::string("fixedTarget"))},
        {EncodableValue("fixedTarget"), EncodableValue(point)},
    };
    const ZoomFocusArgs args = ReadZoomFocusArgs(segment);
    EXPECT_FALSE(args.has_point);
    EXPECT_FALSE(args.fixed_target());
  }
}

}  // namespace
}  // namespace clingfy::bridge
