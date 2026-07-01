// QueryPerformanceCounter-backed frame-time collector for the Windows
// Phase 5 live-compositor POC. Records per-frame durations, computes
// min / median / p99 across the collection window, and prints a single
// summary line on demand.
//
// First used by Stage 1A0 (Direct2D HWND timing harness). The same
// primitive is intended for re-use in Stage 1B (MediaPlayer
// frame-server feeding Direct2D) and Stage 2 (Flutter-rendered
// measurement run) — that re-use is why this lives in its own
// header / .cpp pair rather than inside the demo's translation unit.
//
// Header is standalone: no Windows headers in the interface, no
// dependency on the rest of the runner. The POC build target links
// frame_timing.cpp directly.

#ifndef WINDOWS_RUNNER_PREVIEW_FRAME_TIMING_H_
#define WINDOWS_RUNNER_PREVIEW_FRAME_TIMING_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace clingfy::preview {

struct FrameTimingStats {
  std::size_t frame_count = 0;
  double min_ms = 0.0;
  double median_ms = 0.0;
  double p99_ms = 0.0;
  double max_ms = 0.0;
};

class FrameTimingCollector {
 public:
  // Initialize the QPC frequency once. Reserves space for ~30 seconds of
  // 240Hz samples so the typical POC run stays alloc-free.
  FrameTimingCollector();

  // Mark the start of a frame's work. Pairs with EndFrame().
  void BeginFrame();

  // Mark the end of a frame's work. The elapsed time since the matching
  // BeginFrame() is appended to the sample buffer. If BeginFrame() was
  // not called first, the sample is silently dropped.
  void EndFrame();

  // Drop all collected samples (e.g. between measurement windows).
  void Reset();

  // Compute a snapshot of the current sample set. Safe to call mid-run
  // and after the loop ends. Returns a zeroed struct if no samples have
  // been collected yet.
  FrameTimingStats ComputeStats() const;

  // Format the stats as a single human-readable line, ready to print to
  // stderr or a debug log. Includes the frame count.
  static std::string FormatStats(const FrameTimingStats& stats);

  std::size_t sample_count() const { return samples_qpc_.size(); }

 private:
  // QPC frequency in ticks-per-second. Set once in the constructor and
  // assumed stable for the lifetime of the process (it is per Windows).
  std::int64_t qpc_frequency_ = 0;

  // Last BeginFrame() QPC value. Zero means "no frame in flight."
  std::int64_t last_begin_qpc_ = 0;

  // Per-frame elapsed times in raw QPC ticks. Converted to milliseconds
  // only when stats are computed, so the hot path stays cheap.
  std::vector<std::int64_t> samples_qpc_;
};

}  // namespace clingfy::preview

#endif  // WINDOWS_RUNNER_PREVIEW_FRAME_TIMING_H_
