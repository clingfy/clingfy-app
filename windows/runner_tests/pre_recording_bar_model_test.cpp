#include "Capture/PreRecordingBar/pre_recording_bar_model.h"

#include <gtest/gtest.h>

#include <array>

namespace clingfy::capture {
namespace {

// Workflow phase wire values used across the cases.
constexpr int kIdle = 0;
constexpr int kStarting = 1;
constexpr int kRecording = 2;
constexpr int kPaused = 3;
constexpr int kStopping = 4;
constexpr int kFinalizing = 5;

// Index of a button id within the ordered spec/layout arrays.
int IndexOf(BarButtonId id) {
  for (int i = 0; i < kBarButtonCount; ++i) {
    if (kBarButtonOrder[i] == id) {
      return i;
    }
  }
  return -1;
}

BarButtonSpec SpecFor(const PreRecordingBarInputs& in, BarButtonId id) {
  return ComputeBarButtons(in)[IndexOf(id)];
}

PreRecordingBarInputs IdleInputs() {
  PreRecordingBarInputs in;
  in.phase = kIdle;
  return in;
}

// ---- visibility gate ------------------------------------------------------

TEST(PreRecordingBarModelTest, PhaseGateAllowsOnlyIdleRecordingPaused) {
  EXPECT_TRUE(BarPhaseAllowsBar(kIdle));
  EXPECT_TRUE(BarPhaseAllowsBar(kRecording));
  EXPECT_TRUE(BarPhaseAllowsBar(kPaused));
  EXPECT_FALSE(BarPhaseAllowsBar(kStarting));
  EXPECT_FALSE(BarPhaseAllowsBar(kStopping));
  EXPECT_FALSE(BarPhaseAllowsBar(kFinalizing));
  EXPECT_FALSE(BarPhaseAllowsBar(6));   // openingPreview
  EXPECT_FALSE(BarPhaseAllowsBar(10));  // exporting
}

TEST(PreRecordingBarModelTest, CountdownHidesBarOnlyAtIdle) {
  PreRecordingBarInputs idle = IdleInputs();
  EXPECT_TRUE(ShouldShowBar(idle));
  idle.countdown_active = true;
  EXPECT_FALSE(ShouldShowBar(idle));  // countdown owns the idle pre-roll.

  // A countdown flag left set during recording does NOT hide the bar.
  PreRecordingBarInputs rec;
  rec.phase = kRecording;
  rec.countdown_active = true;
  EXPECT_TRUE(ShouldShowBar(rec));
}

TEST(PreRecordingBarModelTest, DisallowedPhaseNeverShows) {
  PreRecordingBarInputs starting;
  starting.phase = kStarting;
  EXPECT_FALSE(ShouldShowBar(starting));
}

// ---- record glyph ---------------------------------------------------------

TEST(PreRecordingBarModelTest, RecordGlyphFollowsPhase) {
  EXPECT_EQ(RecordGlyphFor(kIdle), RecordGlyph::kRecord);
  EXPECT_EQ(RecordGlyphFor(kRecording), RecordGlyph::kStop);
  EXPECT_EQ(RecordGlyphFor(kPaused), RecordGlyph::kStop);
  EXPECT_EQ(RecordGlyphFor(kStarting), RecordGlyph::kBusy);
  EXPECT_EQ(RecordGlyphFor(kStopping), RecordGlyph::kBusy);
  EXPECT_EQ(RecordGlyphFor(kFinalizing), RecordGlyph::kBusy);
}

// ---- presence -------------------------------------------------------------

TEST(PreRecordingBarModelTest, CoreButtonsPresentWhenIdle) {
  const PreRecordingBarInputs in = IdleInputs();
  for (const BarButtonId id :
       {BarButtonId::kClose, BarButtonId::kDisplay, BarButtonId::kWindow,
        BarButtonId::kArea, BarButtonId::kCamera, BarButtonId::kMic,
        BarButtonId::kSystemAudio, BarButtonId::kRecord}) {
    EXPECT_TRUE(SpecFor(in, id).present);
  }
  // No update available, not recording → those two are absent.
  EXPECT_FALSE(SpecFor(in, BarButtonId::kUpdate).present);
  EXPECT_FALSE(SpecFor(in, BarButtonId::kPauseResume).present);
}

TEST(PreRecordingBarModelTest, UpdateButtonPresentOnlyWhenAvailable) {
  PreRecordingBarInputs in = IdleInputs();
  EXPECT_FALSE(SpecFor(in, BarButtonId::kUpdate).present);
  in.update_available = true;
  EXPECT_TRUE(SpecFor(in, BarButtonId::kUpdate).present);
}

TEST(PreRecordingBarModelTest, PauseResumePresentOnlyWhenCapableAndLive) {
  PreRecordingBarInputs in;
  in.can_pause_resume = true;

  in.phase = kIdle;  // capable but not live.
  EXPECT_FALSE(SpecFor(in, BarButtonId::kPauseResume).present);

  in.phase = kRecording;
  EXPECT_TRUE(SpecFor(in, BarButtonId::kPauseResume).present);
  in.phase = kPaused;
  EXPECT_TRUE(SpecFor(in, BarButtonId::kPauseResume).present);

  in.can_pause_resume = false;  // live but not capable.
  in.phase = kRecording;
  EXPECT_FALSE(SpecFor(in, BarButtonId::kPauseResume).present);
}

// ---- styling --------------------------------------------------------------

TEST(PreRecordingBarModelTest, SourceSelectionAccentsFollowTargetMode) {
  PreRecordingBarInputs in = IdleInputs();

  in.target_mode = 0;  // display
  EXPECT_EQ(SpecFor(in, BarButtonId::kDisplay).style,
            BarButtonStyle::kSelected);
  EXPECT_EQ(SpecFor(in, BarButtonId::kWindow).style, BarButtonStyle::kNormal);
  EXPECT_EQ(SpecFor(in, BarButtonId::kArea).style, BarButtonStyle::kNormal);

  in.target_mode = 2;  // window
  EXPECT_EQ(SpecFor(in, BarButtonId::kWindow).style,
            BarButtonStyle::kSelected);
  EXPECT_EQ(SpecFor(in, BarButtonId::kDisplay).style, BarButtonStyle::kNormal);

  in.target_mode = 3;  // area
  EXPECT_EQ(SpecFor(in, BarButtonId::kArea).style, BarButtonStyle::kSelected);
}

TEST(PreRecordingBarModelTest, ToggleAccentsFollowTheirFlags) {
  PreRecordingBarInputs in = IdleInputs();
  EXPECT_EQ(SpecFor(in, BarButtonId::kCamera).style, BarButtonStyle::kNormal);
  EXPECT_EQ(SpecFor(in, BarButtonId::kMic).style, BarButtonStyle::kNormal);
  EXPECT_EQ(SpecFor(in, BarButtonId::kSystemAudio).style,
            BarButtonStyle::kNormal);

  in.camera_selected = true;
  in.mic_enabled = true;
  in.system_audio_enabled = true;
  EXPECT_EQ(SpecFor(in, BarButtonId::kCamera).style,
            BarButtonStyle::kSelected);
  EXPECT_EQ(SpecFor(in, BarButtonId::kMic).style, BarButtonStyle::kSelected);
  EXPECT_EQ(SpecFor(in, BarButtonId::kSystemAudio).style,
            BarButtonStyle::kSelected);
}

TEST(PreRecordingBarModelTest, PickersDisabledWhileRecordingEvenWhenSelected) {
  PreRecordingBarInputs in;
  in.phase = kRecording;
  in.target_mode = 0;  // display "selected" — but recording disables it.
  in.camera_selected = true;
  for (const BarButtonId id :
       {BarButtonId::kDisplay, BarButtonId::kWindow, BarButtonId::kArea,
        BarButtonId::kCamera, BarButtonId::kMic, BarButtonId::kSystemAudio}) {
    EXPECT_EQ(SpecFor(in, id).style, BarButtonStyle::kDisabled)
        << "button index " << IndexOf(id);
  }
}

TEST(PreRecordingBarModelTest, CloseDisabledOnlyDuringStartAndStop) {
  PreRecordingBarInputs in;
  in.phase = kStarting;
  EXPECT_EQ(SpecFor(in, BarButtonId::kClose).style, BarButtonStyle::kDisabled);
  in.phase = kStopping;
  EXPECT_EQ(SpecFor(in, BarButtonId::kClose).style, BarButtonStyle::kDisabled);
  in.phase = kRecording;
  EXPECT_EQ(SpecFor(in, BarButtonId::kClose).style, BarButtonStyle::kNormal);
  in.phase = kIdle;
  EXPECT_EQ(SpecFor(in, BarButtonId::kClose).style, BarButtonStyle::kNormal);
}

TEST(PreRecordingBarModelTest, PauseResumeDimmedWhileInFlight) {
  PreRecordingBarInputs in;
  in.can_pause_resume = true;
  in.phase = kRecording;
  in.pause_resume_in_flight = true;
  const BarButtonSpec spec = SpecFor(in, BarButtonId::kPauseResume);
  EXPECT_TRUE(spec.present);
  EXPECT_EQ(spec.style, BarButtonStyle::kDisabled);
}

// ---- layout ---------------------------------------------------------------

TEST(PreRecordingBarModelTest, LayoutPacksPresentButtonsLeftToRightNoOverlap) {
  const PreRecordingBarInputs in = IdleInputs();
  const auto specs = ComputeBarButtons(in);
  const int h = kBarBaseHeight;
  const int w = BarContentWidth(specs, h);
  const BarLayout layout = ComputeBarLayout(w, h, specs);

  int prev_right = -1;
  for (int i = 0; i < kBarButtonCount; ++i) {
    const BarButtonRect& r = layout.buttons[i];
    if (!specs[i].present) {
      EXPECT_EQ(r.id, BarButtonId::kNone);  // absent slot is degenerate.
      continue;
    }
    EXPECT_EQ(r.id, specs[i].id);
    EXPECT_LT(r.left, r.right);
    EXPECT_LT(r.top, r.bottom);
    EXPECT_GE(r.left, prev_right);  // no overlap, left-to-right order.
    EXPECT_LE(r.right, w);          // stays within the content width.
    prev_right = r.right;
  }
}

TEST(PreRecordingBarModelTest, ContentWidthGrowsWhenMoreButtonsPresent) {
  PreRecordingBarInputs base = IdleInputs();
  const int narrow = BarContentWidth(ComputeBarButtons(base), kBarBaseHeight);

  base.update_available = true;  // adds the Update button.
  const int wider = BarContentWidth(ComputeBarButtons(base), kBarBaseHeight);
  EXPECT_GT(wider, narrow);
}

TEST(PreRecordingBarModelTest, HitTestFindsButtonUnderPointAndMissesGaps) {
  const PreRecordingBarInputs in = IdleInputs();
  const auto specs = ComputeBarButtons(in);
  const int h = kBarBaseHeight;
  const int w = BarContentWidth(specs, h);
  const BarLayout layout = ComputeBarLayout(w, h, specs);

  // Center of the close button (first present slot) hits it.
  const BarButtonRect& close = layout.buttons[IndexOf(BarButtonId::kClose)];
  const int cx = (close.left + close.right) / 2;
  const int cy = (close.top + close.bottom) / 2;
  EXPECT_EQ(HitTestBarButton(layout, cx, cy), BarButtonId::kClose);

  // Above the button row (in the vertical padding) misses everything.
  EXPECT_EQ(HitTestBarButton(layout, cx, 0), BarButtonId::kNone);
  // Far to the right, past the last button, misses.
  EXPECT_EQ(HitTestBarButton(layout, w + 50, cy), BarButtonId::kNone);
}

TEST(PreRecordingBarModelTest, LayoutEmptyForNonPositiveSize) {
  const auto specs = ComputeBarButtons(IdleInputs());
  const BarLayout layout = ComputeBarLayout(0, 0, specs);
  for (const BarButtonRect& r : layout.buttons) {
    EXPECT_EQ(r.id, BarButtonId::kNone);
  }
}

}  // namespace
}  // namespace clingfy::capture
