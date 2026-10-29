#include "Capture/capture_frame_pacer.h"

namespace clingfy::capture {

namespace {

constexpr std::int64_t kHnsPerSecond = 10'000'000;

}  // namespace

CaptureFramePacer::CaptureFramePacer(int fps)
    : interval_hns_(fps > 0 ? kHnsPerSecond / fps : 0) {}

bool CaptureFramePacer::Keep(std::int64_t timestamp_hns) {
  if (interval_hns_ <= 0) {
    return true;
  }
  if (!started_) {
    started_ = true;
    next_slot_hns_ = timestamp_hns + interval_hns_;
    return true;
  }
  // A quarter interval of slack: a frame that lands a little before its slot
  // (compositor timestamps jitter by a millisecond or more) still takes it.
  // Without it, a 60 Hz source paced to 60 drops frames it should keep. The
  // average rate cannot exceed `fps` because each keep moves the slot by one
  // whole interval, not to the frame's timestamp.
  if (timestamp_hns + interval_hns_ / 4 < next_slot_hns_) {
    return false;
  }
  next_slot_hns_ += interval_hns_;
  // Snap forward after a gap so the grid never trails the kept frame and
  // admits a burst of catch-up frames.
  if (next_slot_hns_ <= timestamp_hns) {
    next_slot_hns_ = timestamp_hns + interval_hns_;
  }
  return true;
}

}  // namespace clingfy::capture
