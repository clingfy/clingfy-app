#ifndef RUNNER_CAPTURE_CAPTURE_FRAME_PACER_H_
#define RUNNER_CAPTURE_CAPTURE_FRAME_PACER_H_

#include <cstdint>

namespace clingfy::capture {

// Caps the recorded frame rate at the user's 30 / 60 fps setting.
//
// Windows.Graphics.Capture delivers a frame whenever the display composes a
// changed one, so a busy 144 Hz monitor hands the encoder up to 144 frames a
// second whatever the user picked; the setting used to reach only the
// encoder's rate attribute. The drain loop asks this pacer about every
// captured frame and drops the ones that arrive before the next slot.
//
// Slots sit on an ideal grid anchored at the first kept frame, not at the last
// kept frame's actual timestamp, so a 60 Hz source paced to 30 keeps exactly
// every other frame even when real timestamps jitter around the slot boundary
// (the same reasoning as the GIF decimator, gif_export_policy.h). A long gap
// (a static screen, a pause) snaps the grid forward rather than letting it
// fall behind and admit a burst.
//
// Pure: no Win32, no clock. Not thread-safe; one per recording, used only on
// the drain thread.
class CaptureFramePacer {
 public:
  // `fps` <= 0 disables pacing (every frame kept).
  explicit CaptureFramePacer(int fps);

  // True when the frame at `timestamp_hns` (100 ns units, monotonic) should be
  // written. A kept frame advances the grid.
  bool Keep(std::int64_t timestamp_hns);

  std::int64_t interval_hns() const { return interval_hns_; }

 private:
  std::int64_t interval_hns_ = 0;
  bool started_ = false;
  std::int64_t next_slot_hns_ = 0;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAPTURE_FRAME_PACER_H_
