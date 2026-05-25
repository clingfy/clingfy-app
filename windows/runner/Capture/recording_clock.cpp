#include "Capture/recording_clock.h"

#include <windows.h>

namespace clingfy::capture {

namespace {

constexpr std::int64_t kHundredNanosPerSecond = 10'000'000;

std::int64_t DefaultQpcNow() {
  LARGE_INTEGER value{};
  ::QueryPerformanceCounter(&value);
  return static_cast<std::int64_t>(value.QuadPart);
}

std::int64_t DefaultQpcFrequency() {
  LARGE_INTEGER value{};
  ::QueryPerformanceFrequency(&value);
  return static_cast<std::int64_t>(value.QuadPart);
}

}  // namespace

RecordingClock::RecordingClock()
    : now_qpc_(&DefaultQpcNow), qpc_frequency_(DefaultQpcFrequency()) {}

RecordingClock::RecordingClock(QpcSource now_qpc, std::int64_t qpc_frequency)
    : now_qpc_(std::move(now_qpc)), qpc_frequency_(qpc_frequency) {}

void RecordingClock::MarkStart() {
  start_qpc_ = now_qpc_ ? now_qpc_() : 0;
  pause_started_qpc_ = 0;
  paused_hns_ = 0;
  paused_ = false;
  started_ = true;
}

void RecordingClock::Pause() {
  if (!started_ || paused_ || !now_qpc_) {
    return;
  }
  pause_started_qpc_ = now_qpc_();
  paused_ = true;
}

void RecordingClock::Resume() {
  if (!started_ || !paused_ || !now_qpc_) {
    return;
  }
  const std::int64_t now = now_qpc_();
  const std::int64_t pause_delta = now - pause_started_qpc_;
  if (pause_delta > 0 && qpc_frequency_ > 0) {
    // Accumulate this pause into the running total. Use the same
    // seconds + remainder split as TicksToHns so multi-minute pauses
    // do not overflow the intermediate multiplication.
    const std::int64_t seconds = pause_delta / qpc_frequency_;
    const std::int64_t remainder = pause_delta % qpc_frequency_;
    paused_hns_ += seconds * kHundredNanosPerSecond +
                    (remainder * kHundredNanosPerSecond) / qpc_frequency_;
  }
  pause_started_qpc_ = 0;
  paused_ = false;
}

std::int64_t RecordingClock::ElapsedHns() const {
  if (!started_ || !now_qpc_) {
    return 0;
  }
  return TicksToHns(now_qpc_());
}

std::int64_t RecordingClock::TicksToHns(std::int64_t qpc_ticks) const {
  if (qpc_frequency_ <= 0) {
    return 0;
  }
  const std::int64_t delta = qpc_ticks - start_qpc_;
  if (delta <= 0) {
    return 0;
  }
  // Split the multiplication to keep 64-bit math safe across multi-hour
  // recordings: `delta * 10_000_000` could overflow for QPC frequencies in
  // the 10 MHz range, but `seconds + remainder` stays bounded.
  const std::int64_t seconds = delta / qpc_frequency_;
  const std::int64_t remainder = delta % qpc_frequency_;
  std::int64_t elapsed = seconds * kHundredNanosPerSecond +
                          (remainder * kHundredNanosPerSecond) / qpc_frequency_;

  // Subtract the cumulative paused time so the encoder sees a
  // continuous timeline — the pause "disappears" from the output MP4.
  // If we're currently paused, also subtract the in-progress pause's
  // partial duration to prevent the clock from "creeping" while the
  // user is sitting on Pause.
  std::int64_t total_paused = paused_hns_;
  if (paused_ && pause_started_qpc_ != 0) {
    const std::int64_t in_progress = qpc_ticks - pause_started_qpc_;
    if (in_progress > 0) {
      const std::int64_t seconds_paused = in_progress / qpc_frequency_;
      const std::int64_t remainder_paused = in_progress % qpc_frequency_;
      total_paused +=
          seconds_paused * kHundredNanosPerSecond +
          (remainder_paused * kHundredNanosPerSecond) / qpc_frequency_;
    }
  }
  elapsed -= total_paused;
  return elapsed > 0 ? elapsed : 0;
}

}  // namespace clingfy::capture
