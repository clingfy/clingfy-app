#include "preview/preview_audio_renderer.h"

#include <gtest/gtest.h>

#include <vector>

#include "Capture/Export/clip_playback_planner.h"

// Editing step 4-7b — headless coverage for the edited-preview audio
// renderer. The WASAPI half needs a real render endpoint and an
// audio-bearing source file, so its streaming behavior is validated
// on-device in slice 4-7c's play-test; what CI pins here is the pure clock
// math (the pacer's audio-master position source, design D5) and the
// soft-fail Open contract (D7: any setup failure -> nullptr -> the preview
// stays a working silent-video preview).

namespace clingfy::preview {
namespace {

TEST(PreviewAudioRendererClockTest, FreshStreamReadsTheBase) {
  // Just primed: everything submitted is still unplayed padding.
  EXPECT_EQ(PreviewAudioRenderer::PlaybackEditedFrame(
                /*base_edited_frame=*/96000, /*submitted_frames=*/9600,
                /*padding_frames=*/9600),
            96000);
}

TEST(PreviewAudioRendererClockTest, AdvancesBySubmittedMinusPadding) {
  EXPECT_EQ(PreviewAudioRenderer::PlaybackEditedFrame(
                /*base_edited_frame=*/48000, /*submitted_frames=*/24000,
                /*padding_frames=*/4800),
            48000 + 19200);
}

TEST(PreviewAudioRendererClockTest, PaddingLargerThanSubmittedClampsToBase) {
  // Transient after a reset: the device may briefly report stale padding —
  // the position must never read BEFORE the primed base.
  EXPECT_EQ(PreviewAudioRenderer::PlaybackEditedFrame(
                /*base_edited_frame=*/1000, /*submitted_frames=*/100,
                /*padding_frames=*/500),
            1000);
}

TEST(PreviewAudioRendererClockTest, ZeroPaddingReadsAllSubmitted) {
  // Fully drained device buffer: everything written has played.
  EXPECT_EQ(PreviewAudioRenderer::PlaybackEditedFrame(
                /*base_edited_frame=*/0, /*submitted_frames=*/48000,
                /*padding_frames=*/0),
            48000);
}

TEST(PreviewAudioRendererClockTest, PlanEndFromLastSlotTiling) {
  // Slots tile contiguously, so the plan end is the last slot's edited
  // start + FULL duration (§5.2 — silence included), ms->frames truncating.
  std::vector<capture::export_::clip_planner::AudioSlot> slots;
  slots.push_back(capture::export_::clip_planner::AudioSlot{
      /*source_in_ms=*/6000, /*edited_start_ms=*/0, /*copy_duration_ms=*/2000,
      /*duration_ms=*/2000});
  slots.push_back(capture::export_::clip_planner::AudioSlot{
      /*source_in_ms=*/0, /*edited_start_ms=*/2000, /*copy_duration_ms=*/500,
      /*duration_ms=*/1500});
  // End = 2000 + 1500 = 3500 ms = 168000 frames at 48 kHz.
  EXPECT_EQ(PreviewAudioRenderer::PlanEndEditedFrame(slots), 168000);
}

TEST(PreviewAudioRendererClockTest, PlanEndOfEmptySlotsIsZero) {
  // Nothing to play: the stream drains immediately and playing() flips
  // false — the D7 audio-less-session behavior.
  EXPECT_EQ(PreviewAudioRenderer::PlanEndEditedFrame({}), 0);
}

TEST(PreviewAudioRendererOpenTest, MissingSourceFailsSoftly) {
  // The pump opens the source before any WASAPI setup, so a bad path must
  // return nullptr (never throw, never crash) with no audio device needed —
  // this is the D7 silent-video fallback CI can exercise headlessly.
  std::vector<capture::export_::clip_planner::AudioSlot> slots;
  slots.push_back(capture::export_::clip_planner::AudioSlot{
      /*source_in_ms=*/0, /*edited_start_ms=*/0, /*copy_duration_ms=*/1000,
      /*duration_ms=*/1000});
  EXPECT_EQ(PreviewAudioRenderer::Open(
                L"C:\\definitely\\not\\a\\real\\file.mov", slots),
            nullptr);
}

TEST(PreviewAudioRendererOpenTest, EmptySlotsFailSoftly) {
  // No slots = nothing to play (the engine never opens a renderer for a
  // passthrough session; an empty plan must not construct a zombie).
  EXPECT_EQ(PreviewAudioRenderer::Open(L"C:\\also\\not\\real.mov", {}),
            nullptr);
}

}  // namespace
}  // namespace clingfy::preview
