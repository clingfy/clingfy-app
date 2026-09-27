#include "Audio/microphone_level.h"

#include <algorithm>
#include <cmath>

namespace clingfy::audio {
namespace {

// Widen `peak` to cover one more buffer.
//
// Drivers do emit NaN after a glitch, and this loop is safe against it
// WITHOUT a guard: every comparison involving NaN is false, so `magnitude >
// peak` rejects it and the running peak keeps its last real value.
// Accumulating instead (an RMS sum, or a max() with the NaN on the left)
// would NOT be safe -- the NaN would propagate through the rest of the
// buffer and the meter would read NaN for a live microphone. Keep the
// comparison in this direction.
float FoldPeak(float peak, const float* samples, std::size_t sample_count) {
  for (std::size_t i = 0; i < sample_count; ++i) {
    const float magnitude = std::fabs(samples[i]);
    if (magnitude > peak) {
      peak = magnitude;
    }
  }
  return peak;
}

MicrophoneLevel LevelFromPeak(float peak) {
  MicrophoneLevel level;
  // Clamped because WASAPI float samples can exceed [-1, 1] on a hot input,
  // and a meter that draws past full is worse than one that pins.
  level.linear = std::clamp(static_cast<double>(peak), 0.0, 1.0);

  if (peak <= 0.0f) {
    // log10(0) is -inf. Report the floor instead so the number stays printable
    // and comparisons against the threshold behave.
    level.dbfs = kMicLevelSilenceDbfs;
  } else {
    level.dbfs =
        std::max(kMicLevelSilenceDbfs, 20.0 * std::log10(level.linear));
  }

  // No lower bound, matching macOS's `MicrophoneLevelSample.isLow`
  // (`dbfs < -32.0`). A microphone that IS delivering buffers and those
  // buffers are digital silence is the WORST case, not an exempt one -- that
  // is a muted or dead endpoint, and it is exactly the take the user loses.
  // Excluding it would mean the same dead microphone warns on a Mac and says
  // nothing on Windows.
  //
  // Dart's fallback band (`dbfs < -32.0 && dbfs > -120.0`,
  // device_controller.dart:521) reads narrower, but it only applies when a
  // platform omits the flag. We always send it, so this is the definition
  // that takes effect -- and it is the one macOS already ships.
  //
  // "No microphone selected" is handled by the UI gate
  // (`_hasSelectedMicrophone && micInputTooLow`) and by
  // [SilentMicrophoneLevel], not by this threshold.
  level.is_low = level.dbfs < kMicLevelLowDbfs;
  return level;
}

}  // namespace

MicrophoneLevel SilentMicrophoneLevel() {
  MicrophoneLevel level;
  level.linear = 0.0;
  level.dbfs = kMicLevelSilenceDbfs;
  // NOT true, and deliberately different from `LevelFromPeak(0)` above.
  //
  // The distinction is "no data" vs "data that is silent". This sentinel is
  // the first, and it means a deselected microphone or a stopped monitor --
  // warning there would fire on every launch and teach the user to ignore the
  // warning. A zero-filled buffer from a running capture is the second, and
  // that one warns.
  level.is_low = false;
  return level;
}

MicrophoneLevel ComputeMicrophoneLevel(const float* samples,
                                       std::size_t sample_count) {
  if (samples == nullptr || sample_count == 0) {
    return SilentMicrophoneLevel();
  }
  return LevelFromPeak(FoldPeak(0.0f, samples, sample_count));
}

MicrophoneLevelAccumulator::MicrophoneLevelAccumulator(
    std::chrono::steady_clock::duration interval)
    : interval_(interval) {}

void MicrophoneLevelAccumulator::Add(const float* samples,
                                     std::size_t sample_count) {
  if (samples == nullptr || sample_count == 0) {
    return;
  }
  peak_ = FoldPeak(peak_, samples, sample_count);
}

std::optional<MicrophoneLevel> MicrophoneLevelAccumulator::TakeIfDue(
    std::chrono::steady_clock::time_point now) {
  if (scheduled_ && now < next_emit_) {
    return std::nullopt;
  }

  const MicrophoneLevel level = LevelFromPeak(peak_);
  peak_ = 0.0f;

  // Deadline from NOW, not the previous deadline plus one interval. Advancing
  // the old one tries to catch up after a stall: if the consumer thread is
  // descheduled for a second, a catch-up schedule fires fifteen events back to
  // back, every one of them reporting the same stale peak. A meter is a live
  // readout -- a missed window is gone, not owed.
  scheduled_ = true;
  next_emit_ = now + interval_;
  return level;
}

void MicrophoneLevelAccumulator::Reset() {
  peak_ = 0.0f;
  scheduled_ = false;
  next_emit_ = {};
}

}  // namespace clingfy::audio
