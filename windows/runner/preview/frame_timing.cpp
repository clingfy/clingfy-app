#include "preview/frame_timing.h"

#include <algorithm>
#include <cstdio>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace clingfy::preview {

namespace {

std::int64_t QueryQpcNow() {
  LARGE_INTEGER now{};
  QueryPerformanceCounter(&now);
  return static_cast<std::int64_t>(now.QuadPart);
}

std::int64_t QueryQpcFrequency() {
  LARGE_INTEGER freq{};
  QueryPerformanceFrequency(&freq);
  return static_cast<std::int64_t>(freq.QuadPart);
}

double TicksToMs(std::int64_t ticks, std::int64_t frequency) {
  if (frequency <= 0) {
    return 0.0;
  }
  return (static_cast<double>(ticks) * 1000.0) /
         static_cast<double>(frequency);
}

// Percentile from a SORTED vector. Uses nearest-rank with linear
// interpolation for stability on small samples.
double PercentileMs(const std::vector<std::int64_t>& sorted_ticks,
                    std::int64_t frequency, double percentile) {
  if (sorted_ticks.empty()) {
    return 0.0;
  }
  const double rank =
      percentile * static_cast<double>(sorted_ticks.size() - 1);
  const auto lower_idx = static_cast<std::size_t>(rank);
  const auto upper_idx =
      std::min<std::size_t>(lower_idx + 1, sorted_ticks.size() - 1);
  const double frac = rank - static_cast<double>(lower_idx);
  const double lower_ms = TicksToMs(sorted_ticks[lower_idx], frequency);
  const double upper_ms = TicksToMs(sorted_ticks[upper_idx], frequency);
  return lower_ms + (upper_ms - lower_ms) * frac;
}

}  // namespace

FrameTimingCollector::FrameTimingCollector()
    : qpc_frequency_(QueryQpcFrequency()) {
  // 240Hz * 30s = 7200 samples. A typical POC run is well under this
  // and the reserve keeps the hot path free of reallocation.
  samples_qpc_.reserve(7200);
}

void FrameTimingCollector::BeginFrame() { last_begin_qpc_ = QueryQpcNow(); }

void FrameTimingCollector::EndFrame() {
  if (last_begin_qpc_ == 0) {
    return;
  }
  const std::int64_t now = QueryQpcNow();
  const std::int64_t elapsed = now - last_begin_qpc_;
  if (elapsed > 0) {
    samples_qpc_.push_back(elapsed);
  }
  last_begin_qpc_ = 0;
}

void FrameTimingCollector::Reset() {
  samples_qpc_.clear();
  last_begin_qpc_ = 0;
}

FrameTimingStats FrameTimingCollector::ComputeStats() const {
  FrameTimingStats stats;
  if (samples_qpc_.empty() || qpc_frequency_ <= 0) {
    return stats;
  }
  std::vector<std::int64_t> sorted = samples_qpc_;
  std::sort(sorted.begin(), sorted.end());
  stats.frame_count = sorted.size();
  stats.min_ms = TicksToMs(sorted.front(), qpc_frequency_);
  stats.max_ms = TicksToMs(sorted.back(), qpc_frequency_);
  stats.median_ms = PercentileMs(sorted, qpc_frequency_, 0.50);
  stats.p99_ms = PercentileMs(sorted, qpc_frequency_, 0.99);
  return stats;
}

std::string FrameTimingCollector::FormatStats(const FrameTimingStats& stats) {
  // Fixed-width output so successive runs are easy to compare by eye.
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "frames=%zu  min=%6.3f ms  median=%6.3f ms  p99=%6.3f ms  "
                "max=%6.3f ms",
                stats.frame_count, stats.min_ms, stats.median_ms,
                stats.p99_ms, stats.max_ms);
  return std::string(buf);
}

}  // namespace clingfy::preview
