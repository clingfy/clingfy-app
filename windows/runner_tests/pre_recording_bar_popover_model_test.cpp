#include "Capture/PreRecordingBar/pre_recording_bar_popover_model.h"

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

TEST(PreRecordingBarPopoverModelTest, StacksRowsWithTopAndBottomPadding) {
  const PopoverLayout layout = ComputePopoverLayout(/*count=*/3, /*width=*/200,
                                                    /*row_height=*/30,
                                                    /*vpad=*/6);
  EXPECT_EQ(layout.width, 200);
  EXPECT_EQ(layout.height, 2 * 6 + 3 * 30);  // vpad top+bottom + 3 rows.
  ASSERT_EQ(layout.rows.size(), 3u);

  EXPECT_EQ(layout.rows[0].top, 6);
  EXPECT_EQ(layout.rows[0].bottom, 36);
  EXPECT_EQ(layout.rows[1].top, 36);
  EXPECT_EQ(layout.rows[2].top, 66);
  EXPECT_EQ(layout.rows[2].bottom, 96);
  for (const PopoverRowRect& r : layout.rows) {
    EXPECT_EQ(r.left, 0);
    EXPECT_EQ(r.right, 200);
  }
}

TEST(PreRecordingBarPopoverModelTest, HitTestFindsRowAndMissesPaddingAndSides) {
  const PopoverLayout layout = ComputePopoverLayout(3, 200, 30, 6);

  // Middle of row 1.
  EXPECT_EQ(HitTestPopoverRow(layout, 100, 50), 1);
  // First and last rows.
  EXPECT_EQ(HitTestPopoverRow(layout, 10, 20), 0);
  EXPECT_EQ(HitTestPopoverRow(layout, 10, 80), 2);
  // Top padding band (y < vpad) misses.
  EXPECT_EQ(HitTestPopoverRow(layout, 100, 3), -1);
  // Below the last row misses.
  EXPECT_EQ(HitTestPopoverRow(layout, 100, 200), -1);
  // Outside the width misses.
  EXPECT_EQ(HitTestPopoverRow(layout, 300, 50), -1);
}

TEST(PreRecordingBarPopoverModelTest, EmptyForNonPositiveInputs) {
  EXPECT_EQ(ComputePopoverLayout(0, 200, 30, 6).rows.size(), 0u);
  EXPECT_EQ(ComputePopoverLayout(0, 200, 30, 6).height, 0);
  EXPECT_EQ(ComputePopoverLayout(3, 0, 30, 6).rows.size(), 0u);
  EXPECT_EQ(ComputePopoverLayout(3, 200, 0, 6).rows.size(), 0u);
}

}  // namespace
}  // namespace clingfy::capture
