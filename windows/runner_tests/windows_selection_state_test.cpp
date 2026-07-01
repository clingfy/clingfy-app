#include "Capture/windows_selection_state.h"

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

class WindowsSelectionStateTest : public ::testing::Test {
 protected:
  void SetUp() override {
    WindowsSelectionState::Instance().ResetForTesting();
  }
  void TearDown() override {
    WindowsSelectionState::Instance().ResetForTesting();
  }
};

TEST_F(WindowsSelectionStateTest, FreshStateHasNoDisplaySelection) {
  EXPECT_FALSE(WindowsSelectionState::Instance().DisplayId().has_value());
  EXPECT_EQ(WindowsSelectionState::Instance().TargetMode(),
            DisplayTargetMode::kExplicitId);
  EXPECT_FALSE(WindowsSelectionState::Instance().MicrophoneId().has_value());
  EXPECT_FALSE(WindowsSelectionState::Instance().AppWindowId().has_value());
  EXPECT_FALSE(
      WindowsSelectionState::Instance().CurrentAreaRegion().has_value());
  EXPECT_FALSE(WindowsSelectionState::Instance().VideoSourceId().has_value());
}

TEST_F(WindowsSelectionStateTest, AreaRegionRoundTripsAndClears) {
  AreaRegion region;
  region.display_id = std::int64_t{42};
  region.x = 10;
  region.y = 20;
  region.width = 640;
  region.height = 480;
  WindowsSelectionState::Instance().SetAreaRegion(region);

  const auto stored = WindowsSelectionState::Instance().CurrentAreaRegion();
  ASSERT_TRUE(stored.has_value());
  EXPECT_EQ(stored->display_id, std::optional<std::int64_t>(42));
  EXPECT_EQ(stored->x, 10);
  EXPECT_EQ(stored->y, 20);
  EXPECT_EQ(stored->width, 640);
  EXPECT_EQ(stored->height, 480);

  WindowsSelectionState::Instance().SetAreaRegion(std::nullopt);
  EXPECT_FALSE(
      WindowsSelectionState::Instance().CurrentAreaRegion().has_value());
}

TEST_F(WindowsSelectionStateTest, AppWindowIdRoundTrips) {
  WindowsSelectionState::Instance().SetAppWindowId(std::int64_t{99887766});
  ASSERT_TRUE(WindowsSelectionState::Instance().AppWindowId().has_value());
  EXPECT_EQ(*WindowsSelectionState::Instance().AppWindowId(), 99887766);
}

TEST_F(WindowsSelectionStateTest, ClearingAppWindowIdResetsSelection) {
  WindowsSelectionState::Instance().SetAppWindowId(std::int64_t{5});
  WindowsSelectionState::Instance().SetAppWindowId(std::nullopt);
  EXPECT_FALSE(WindowsSelectionState::Instance().AppWindowId().has_value());
}

TEST_F(WindowsSelectionStateTest, SetDisplayIdRoundTrips) {
  WindowsSelectionState::Instance().SetDisplayId(424242);
  ASSERT_TRUE(WindowsSelectionState::Instance().DisplayId().has_value());
  EXPECT_EQ(*WindowsSelectionState::Instance().DisplayId(), 424242);
}

TEST_F(WindowsSelectionStateTest, ClearingDisplayIdResetsSelection) {
  WindowsSelectionState::Instance().SetDisplayId(7);
  WindowsSelectionState::Instance().SetDisplayId(std::nullopt);
  EXPECT_FALSE(WindowsSelectionState::Instance().DisplayId().has_value());
}

TEST_F(WindowsSelectionStateTest, TargetModeRoundTrip) {
  WindowsSelectionState::Instance().SetTargetMode(
      DisplayTargetMode::kAreaRecording);
  EXPECT_EQ(WindowsSelectionState::Instance().TargetMode(),
            DisplayTargetMode::kAreaRecording);
}

TEST_F(WindowsSelectionStateTest, MicrophoneIdRoundTrip) {
  WindowsSelectionState::Instance().SetMicrophoneId(std::string("{abc}"));
  ASSERT_TRUE(WindowsSelectionState::Instance().MicrophoneId().has_value());
  EXPECT_EQ(*WindowsSelectionState::Instance().MicrophoneId(), "{abc}");
}

TEST_F(WindowsSelectionStateTest, VideoSourceIdRoundTrips) {
  WindowsSelectionState::Instance().SetVideoSourceId(
      std::string("\\\\?\\usb#vid_046d&pid_0825"));
  ASSERT_TRUE(WindowsSelectionState::Instance().VideoSourceId().has_value());
  EXPECT_EQ(*WindowsSelectionState::Instance().VideoSourceId(),
            "\\\\?\\usb#vid_046d&pid_0825");
}

TEST_F(WindowsSelectionStateTest, ClearingVideoSourceIdResetsSelection) {
  WindowsSelectionState::Instance().SetVideoSourceId(std::string("{cam}"));
  WindowsSelectionState::Instance().SetVideoSourceId(std::nullopt);
  EXPECT_FALSE(WindowsSelectionState::Instance().VideoSourceId().has_value());
}

TEST(TargetModeMappingTest, TargetModeFromIntCoversAllValuesAndFallsBack) {
  EXPECT_EQ(TargetModeFromInt(0), DisplayTargetMode::kExplicitId);
  EXPECT_EQ(TargetModeFromInt(1), DisplayTargetMode::kAppWindow);
  EXPECT_EQ(TargetModeFromInt(2), DisplayTargetMode::kSingleAppWindow);
  EXPECT_EQ(TargetModeFromInt(3), DisplayTargetMode::kAreaRecording);
  EXPECT_EQ(TargetModeFromInt(4), DisplayTargetMode::kMouseAtStart);
  EXPECT_EQ(TargetModeFromInt(5), DisplayTargetMode::kFollowMouse);
  // Out-of-range values fall back to explicitId so a future Dart enum
  // value cannot wedge the Windows setter.
  EXPECT_EQ(TargetModeFromInt(99), DisplayTargetMode::kExplicitId);
  EXPECT_EQ(TargetModeFromInt(-1), DisplayTargetMode::kExplicitId);
}

TEST(TargetModeMappingTest, TargetModeNameCoversEveryValue) {
  EXPECT_STREQ(TargetModeName(DisplayTargetMode::kExplicitId), "explicitId");
  EXPECT_STREQ(TargetModeName(DisplayTargetMode::kAppWindow), "appWindow");
  EXPECT_STREQ(TargetModeName(DisplayTargetMode::kSingleAppWindow),
               "singleAppWindow");
  EXPECT_STREQ(TargetModeName(DisplayTargetMode::kAreaRecording),
               "areaRecording");
  EXPECT_STREQ(TargetModeName(DisplayTargetMode::kMouseAtStart),
               "mouseAtStart");
  EXPECT_STREQ(TargetModeName(DisplayTargetMode::kFollowMouse), "followMouse");
}

}  // namespace
}  // namespace clingfy::capture
