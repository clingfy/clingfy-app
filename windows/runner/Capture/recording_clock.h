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

  // Phase 4: pause / resume. The clock accumulates the wall-clock
  // time spent paused so that subsequent `ElapsedHns()` calls subtract
  // it — i.e. a recording that pauses for 5 s does NOT produce 5 s of
  // frozen frame timestamps in the output MP4. The encoder samples
  // continue from where they left off in encoded-time.
  //
  // Pause/Resume pairs MUST be balanced; calling Pause when already
  // paused is a no-op (idempotent), and Resume when not paused is
  // also a no-op. The engine's state machine guards the order.
  void Pause();
  void Resume();
  bool paused() const { return paused_; }
  // Cumulative paused duration in 100-ns units. Public for tests.
  std::int64_t paused_hns() const { return paused_hns_; }

  // Returns the elapsed time since `MarkStart` in 100-nanosecond units,
  // MINUS any time the clock spent paused. Returns 0 if `MarkStart` has
  // not been called yet.
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
  // QPC tick stamped when Pause() fired; 0 when not paused.
  std::int64_t pause_started_qpc_ = 0;
  // Sum of all completed pause intervals in 100-ns units.
  std::int64_t paused_hns_ = 0;
  bool started_ = false;
  bool paused_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_CLOCK_H_
