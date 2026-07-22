// Tests for the shared clips wire parser (editing port). Mirrors the macOS
// ClipKeptRange.fromFlutter semantics: enabled-only, positive windows only,
// timeline order preserved, truncating numeric coercion.

#include "Bridge/Routers/clip_args.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>

namespace clingfy::bridge {
namespace {

using capture::export_::clip_planner::ClipKeptRange;

flutter::EncodableValue Key(const char* k) {
  return flutter::EncodableValue(std::string(k));
}

flutter::EncodableValue Clip(std::int64_t in_ms, std::int64_t out_ms,
                             bool enabled = true) {
  flutter::EncodableMap m;
  m[Key("id")] = flutter::EncodableValue(std::string("c"));
  m[Key("sourceInMs")] = flutter::EncodableValue(in_ms);
  m[Key("sourceOutMs")] = flutter::EncodableValue(out_ms);
  m[Key("timelineStartMs")] = flutter::EncodableValue(std::int64_t{0});
  m[Key("enabled")] = flutter::EncodableValue(enabled);
  return flutter::EncodableValue(m);
}

TEST(ClipArgsTest, ParsesEnabledClipsInTimelineOrder) {
  // Reordered (arrange): timeline order B then A must be preserved.
  flutter::EncodableList list{Clip(6000, 8000), Clip(0, 2000)};
  const flutter::EncodableValue value(list);
  const auto ranges = ParseClipRanges(&value);
  ASSERT_EQ(ranges.size(), 2u);
  EXPECT_EQ(ranges[0], (ClipKeptRange{6000, 8000}));
  EXPECT_EQ(ranges[1], (ClipKeptRange{0, 2000}));
}

TEST(ClipArgsTest, DropsDisabledAndDegenerateClips) {
  flutter::EncodableList list{
      Clip(0, 4000),
      Clip(4000, 6000, /*enabled=*/false),  // disabled → dropped
      Clip(6000, 6000),                     // zero-length → dropped
      Clip(9000, 8000),                     // negative window → dropped
      Clip(6000, 10000),
  };
  const flutter::EncodableValue value(list);
  const auto ranges = ParseClipRanges(&value);
  ASSERT_EQ(ranges.size(), 2u);
  EXPECT_EQ(ranges[0], (ClipKeptRange{0, 4000}));
  EXPECT_EQ(ranges[1], (ClipKeptRange{6000, 10000}));
}

TEST(ClipArgsTest, NullNonListAndMissingKeyYieldEmpty) {
  EXPECT_TRUE(ParseClipRanges(nullptr).empty());
  const flutter::EncodableValue not_a_list(std::string("nope"));
  EXPECT_TRUE(ParseClipRanges(&not_a_list).empty());
  flutter::EncodableMap bare;
  EXPECT_TRUE(ReadClipRangesArg(bare).empty());
}

TEST(ClipArgsTest, CoercesDoublesByTruncation) {
  // §5.1: every seconds→ms conversion in the clip path truncates. A double
  // 3999.9 must become 3999, never 4000.
  flutter::EncodableMap m;
  m[Key("sourceInMs")] = flutter::EncodableValue(0.9);
  m[Key("sourceOutMs")] = flutter::EncodableValue(3999.9);
  flutter::EncodableList list{flutter::EncodableValue(m)};
  const flutter::EncodableValue value(list);
  const auto ranges = ParseClipRanges(&value);
  ASSERT_EQ(ranges.size(), 1u);
  EXPECT_EQ(ranges[0].source_in_ms, 0);
  EXPECT_EQ(ranges[0].source_out_ms, 3999);
}

TEST(ClipArgsTest, ReadClipRangesArgFindsList) {
  flutter::EncodableList list{Clip(0, 4000), Clip(6000, 10000)};
  flutter::EncodableMap args;
  args[Key("projectPath")] = flutter::EncodableValue(std::string("x"));
  args[Key("clips")] = flutter::EncodableValue(list);
  const auto ranges = ReadClipRangesArg(args);
  EXPECT_EQ(ranges.size(), 2u);
}

}  // namespace
}  // namespace clingfy::bridge
