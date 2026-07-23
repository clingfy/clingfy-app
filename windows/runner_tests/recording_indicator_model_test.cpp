#include "Capture/Indicator/recording_indicator_model.h"

#include <gtest/gtest.h>

#include "Capture/recording_session_state.h"

// Slice 1 (Windows recording indicator): the pure model behind the pill. These
// mirror macOS `RecordingIndicatorCoordinatorTests` for the shared state-map +
// elapsed-formatter parity, plus Windows-only placement math.
namespace clingfy::capture {
namespace {

// --- IndicatorStateFor: state truth table (parity with macOS
// indicatorState(for:)) ------------------------------------------------------

TEST(RecordingIndicatorModelTest, RecordingMapsToRecording) {
  EXPECT_EQ(IndicatorStateFor(RecordingState::kRecording),
            IndicatorVisualState::kRecording);
}

TEST(RecordingIndicatorModelTest, ResumingReadsAsRecording) {
  EXPECT_EQ(IndicatorStateFor(RecordingState::kResuming),
            IndicatorVisualState::kRecording);
}

TEST(RecordingIndicatorModelTest, PausedMapsToPaused) {
  EXPECT_EQ(IndicatorStateFor(RecordingState::kPaused),
            IndicatorVisualState::kPaused);
}

TEST(RecordingIndicatorModelTest, PausingReadsAsPaused) {
  EXPECT_EQ(IndicatorStateFor(RecordingState::kPausing),
            IndicatorVisualState::kPaused);
}

TEST(RecordingIndicatorModelTest, StoppingMapsToStopping) {
  EXPECT_EQ(IndicatorStateFor(RecordingState::kStopping),
            IndicatorVisualState::kStopping);
}

TEST(RecordingIndicatorModelTest, IdleMapsToHidden) {
  EXPECT_EQ(IndicatorStateFor(RecordingState::kIdle),
            IndicatorVisualState::kHidden);
}

TEST(RecordingIndicatorModelTest, StartingMapsToHidden) {
  // The pill is not shown until the recording is actually live — .starting
  // collapses to hidden (macOS parity).
  EXPECT_EQ(IndicatorStateFor(RecordingState::kStarting),
            IndicatorVisualState::kHidden);
}

TEST(RecordingIndicatorModelTest, TerminalStatesMapToHidden) {
  EXPECT_EQ(IndicatorStateFor(RecordingState::kStopped),
            IndicatorVisualState::kHidden);
  EXPECT_EQ(IndicatorStateFor(RecordingState::kFailed),
            IndicatorVisualState::kHidden);
}

// --- FormatIndicatorElapsed: HH:MM:SS parity with macOS formatElapsed -------

TEST(RecordingIndicatorModelTest, FormatZero) {
  EXPECT_EQ(FormatIndicatorElapsed(0), "00:00:00");
}

TEST(RecordingIndicatorModelTest, FormatSubMinute) {
  EXPECT_EQ(FormatIndicatorElapsed(7), "00:00:07");
}

TEST(RecordingIndicatorModelTest, FormatExactMinute) {
  EXPECT_EQ(FormatIndicatorElapsed(60), "00:01:00");
}

TEST(RecordingIndicatorModelTest, FormatMixedHourMinuteSecond) {
  // 1*3600 + 23*60 + 45 = 5025
  EXPECT_EQ(FormatIndicatorElapsed(5025), "01:23:45");
}

TEST(RecordingIndicatorModelTest, FormatTenHoursStillHHMMSS) {
  // 10*3600 + 4 = 36004
  EXPECT_EQ(FormatIndicatorElapsed(36004), "10:00:04");
}

TEST(RecordingIndicatorModelTest, FormatHoursNotCappedAtTwoDigits) {
  // macOS DateComponentsFormatter grows the hours field; 100h renders 3 digits.
  EXPECT_EQ(FormatIndicatorElapsed(100ull * 3600), "100:00:00");
}

// --- ComputeIndicatorRect: top-right placement, DPI-scaled, clamped ---------

TEST(RecordingIndicatorModelTest, PlacesTopRightAt100Percent) {
  // 1920x1080 work area at 96 dpi, base pill 132x40.
  const IndicatorRect r =
      ComputeIndicatorRect(0, 0, 1920, 1080, 1.0, 132, 40);
  EXPECT_EQ(r.width, 132);
  EXPECT_EQ(r.height, 40);
  EXPECT_EQ(r.x, 1920 - 132 - 24);  // right inset 24
  EXPECT_EQ(r.y, 0 + 36);           // top inset 36
}

TEST(RecordingIndicatorModelTest, ScalesSizeAndInsetsWithDpi) {
  // 150% scale doubles nothing but scales size + insets by 1.5.
  const IndicatorRect r =
      ComputeIndicatorRect(0, 0, 3840, 2160, 1.5, 132, 40);
  EXPECT_EQ(r.width, 198);   // 132 * 1.5
  EXPECT_EQ(r.height, 60);   // 40 * 1.5
  EXPECT_EQ(r.x, 3840 - 198 - 36);  // right inset 24*1.5 = 36
  EXPECT_EQ(r.y, 54);               // top inset 36*1.5 = 54
}

TEST(RecordingIndicatorModelTest, RespectsWorkAreaOrigin) {
  // A non-zero work-area origin (taskbar on the left / top, secondary monitor).
  const IndicatorRect r =
      ComputeIndicatorRect(100, 50, 2020, 1130, 1.0, 132, 40);
  EXPECT_EQ(r.x, 2020 - 132 - 24);
  EXPECT_EQ(r.y, 50 + 36);
}

TEST(RecordingIndicatorModelTest, ClampsIntoTinyWorkArea) {
  // A work area smaller than the pill pins it to the top-left instead of
  // spilling off-screen (x/y never below the work-area origin).
  const IndicatorRect r = ComputeIndicatorRect(0, 0, 80, 20, 1.0, 132, 40);
  EXPECT_GE(r.x, 0);
  EXPECT_GE(r.y, 0);
  EXPECT_EQ(r.x, 0);
  EXPECT_EQ(r.y, 0);
}

TEST(RecordingIndicatorModelTest, NonPositiveScaleTreatedAsOneToOne) {
  const IndicatorRect r = ComputeIndicatorRect(0, 0, 1920, 1080, 0.0, 132, 40);
  EXPECT_EQ(r.width, 132);
  EXPECT_EQ(r.height, 40);
}

// --- ComputeIndicatorButtons / HitTestIndicatorButton (Slice 2) -------------

TEST(RecordingIndicatorModelTest, RecordingShowsPauseAndStop) {
  const IndicatorButtonLayout l = ComputeIndicatorButtons(
      220, 44, IndicatorVisualState::kRecording, /*can_pause_resume=*/true);
  EXPECT_TRUE(l.primary.present);
  EXPECT_TRUE(l.stop.present);
  // Stop is pinned to the right of primary.
  EXPECT_GT(l.stop.left, l.primary.left);
  // Both sit inside the client width and are square-ish.
  EXPECT_LE(l.stop.right, 220);
  EXPECT_EQ(l.primary.bottom - l.primary.top, l.primary.right - l.primary.left);
}

TEST(RecordingIndicatorModelTest, PausedStillShowsPrimaryAndStop) {
  const IndicatorButtonLayout l = ComputeIndicatorButtons(
      220, 44, IndicatorVisualState::kPaused, /*can_pause_resume=*/true);
  EXPECT_TRUE(l.primary.present);  // now means "resume"
  EXPECT_TRUE(l.stop.present);
}

TEST(RecordingIndicatorModelTest, PrimarySuppressedWhenPauseUnavailable) {
  const IndicatorButtonLayout l = ComputeIndicatorButtons(
      220, 44, IndicatorVisualState::kRecording, /*can_pause_resume=*/false);
  EXPECT_FALSE(l.primary.present);
  EXPECT_TRUE(l.stop.present);  // stop still available
}

TEST(RecordingIndicatorModelTest, HiddenAndStoppingHaveNoButtons) {
  const IndicatorButtonLayout hidden = ComputeIndicatorButtons(
      220, 44, IndicatorVisualState::kHidden, true);
  EXPECT_FALSE(hidden.primary.present);
  EXPECT_FALSE(hidden.stop.present);

  const IndicatorButtonLayout stopping = ComputeIndicatorButtons(
      220, 44, IndicatorVisualState::kStopping, true);
  EXPECT_FALSE(stopping.primary.present);
  EXPECT_FALSE(stopping.stop.present);
}

TEST(RecordingIndicatorModelTest, HitTestPrimaryAndStop) {
  const IndicatorButtonLayout l = ComputeIndicatorButtons(
      220, 44, IndicatorVisualState::kRecording, true);

  // A point in the center of each button hits it.
  const int py = (l.primary.top + l.primary.bottom) / 2;
  const int px = (l.primary.left + l.primary.right) / 2;
  EXPECT_EQ(HitTestIndicatorButton(l, px, py), IndicatorButton::kPrimary);

  const int sy = (l.stop.top + l.stop.bottom) / 2;
  const int sx = (l.stop.left + l.stop.right) / 2;
  EXPECT_EQ(HitTestIndicatorButton(l, sx, sy), IndicatorButton::kStop);

  // The timer area on the far left hits nothing.
  EXPECT_EQ(HitTestIndicatorButton(l, 4, 22), IndicatorButton::kNone);
}

TEST(RecordingIndicatorModelTest, HitTestMissesWhenButtonsAbsent) {
  const IndicatorButtonLayout l = ComputeIndicatorButtons(
      220, 44, IndicatorVisualState::kStopping, true);
  EXPECT_EQ(HitTestIndicatorButton(l, 200, 22), IndicatorButton::kNone);
}

}  // namespace
}  // namespace clingfy::capture
