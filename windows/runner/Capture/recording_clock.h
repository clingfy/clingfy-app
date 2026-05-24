#ifndef RUNNER_CAPTURE_RECORDING_CLOCK_H_
#define RUNNER_CAPTURE_RECORDING_CLOCK_H_

#include <cstdint>
#include <functional>

// Wall-clock helper that converts QueryPerformanceCounter ticks into the
// 100-nanosecond units used by Media Foundation sample timestamps.
//
// Phase 3A introduces it ahead of any real capture so that Phase 3B/C/D can
// drop it into the video and audio pipelines without churning the
// dependency graph. The class is deliberately small and pure: all
// platform-specific calls go through the injected functor + frequency, so
// `recording_clock_test.cpp` can exercise the conversion math
// deterministically with a fake clock.
//
// 100-ns units are the Media Foundation convention: 10 million units == 1
// second. Ticks are multiplied by `10_000_000 / qpc_frequency` to avoid
// 64-bit overflow over multi-hour recordings.
namespace clingfy::capture {

using QpcSource = std::function<std::int64_t()>;

class RecordingClock {
 public:
  // Default constructor uses `QueryPerformanceCounter` /
  // `QueryPerformanceFrequency`. Tests should use the two-argument form to
  // inject a fake source.
  RecordingClock();

  RecordingClock(QpcSource now_qpc, std::int64_t qpc_frequency);

  // Stamps "now" as the start of the recording. Call once when the engine
  // transitions Starting -> Recording. Safe to call again to re-base.
  void MarkStart();

  // Returns the elapsed time since `MarkStart` in 100-nanosecond units.
  // Returns 0 if `MarkStart` has not been called yet (Phase 3A skeleton
  // never queries the clock from outside its tests, but the contract is
  // already defined so encoders in later phases can rely on it).
  std::int64_t ElapsedHns() const;

  // Same as ElapsedHns but takes an explicit QPC tick value — used by the
  // capture callback when it already has a timestamp from
  // WGC / WASAPI and just needs the 100-ns conversion.
  std::int64_t TicksToHns(std::int64_t qpc_ticks) const;

  // True between MarkStart and the next call to MarkStart / destruction.
  bool started() const { return started_; }

  std::int64_t qpc_frequency() const { return qpc_frequency_; }

 private:
  QpcSource now_qpc_;
  std::int64_t qpc_frequency_ = 0;
  std::int64_t start_qpc_ = 0;
  bool started_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_CLOCK_H_
