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
  started_ = true;
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
  return seconds * kHundredNanosPerSecond +
         (remainder * kHundredNanosPerSecond) / qpc_frequency_;
}

}  // namespace clingfy::capture
