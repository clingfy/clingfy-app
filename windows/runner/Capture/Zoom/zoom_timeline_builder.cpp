#include "Capture/Zoom/zoom_timeline_builder.h"

#include <algorithm>
#include <cmath>

#include "Capture/Zoom/zoom_hysteresis.h"
#include "preview/zoom_easing_constants.h"

namespace clingfy::capture {

namespace {

std::int64_t RoundMs(double seconds) {
  return static_cast<std::int64_t>(std::llround(seconds * 1000.0));
}

}  // namespace

std::vector<ZoomSegment> BuildZoomSegments(
    const std::vector<CursorSidecarSample>& samples,
    const std::vector<CursorSidecarClick>& clicks, std::int64_t duration_ms,
    double fps, double click_hold_seconds) {
  std::vector<ZoomSegment> empty;
  if (samples.empty() || clicks.empty()) {
    return empty;  // nothing to gate on, or no triggers → no zoom.
  }
  if (fps <= 0.0) {
    fps = clingfy::preview::kZoomTimelineSimulationFPS;
  }

  // Effective duration: prefer the decoder's, else derive from the last event.
  std::int64_t effective_ms = duration_ms;
  if (effective_ms <= 0) {
    effective_ms = std::max(samples.back().t_ms, clicks.back().t_ms);
  }
  if (effective_ms <= 0) {
    return empty;
  }
  const double duration_seconds = static_cast<double>(effective_ms) / 1000.0;
  const std::int64_t hold_ms = RoundMs(click_hold_seconds);

  ZoomHysteresis hysteresis;
  std::vector<ZoomSegment> segments;
  bool has_segment_start = false;
  double segment_start = 0.0;
  bool last_stable = false;
  bool last_raw = false;
  double raw_changed_at = 0.0;

  // Pointer scans over the (sorted) samples + clicks, mirroring macOS's
  // frameIndex pointer for O(steps + samples) total work.
  std::size_t sample_index = 0;
  std::size_t click_index = 0;
  std::int64_t last_click_ms = -1;

  const int total_steps = static_cast<int>(duration_seconds * fps);
  for (int i = 0; i <= total_steps; ++i) {
    const double time = static_cast<double>(i) / fps;
    const std::int64_t step_ms = RoundMs(time);

    // Most recent cursor sample at/before `time`.
    while (sample_index + 1 < samples.size() &&
           samples[sample_index + 1].t_ms <= step_ms) {
      ++sample_index;
    }
    const bool in_bounds = samples[sample_index].visible;

    if (!in_bounds) {
      if (last_stable && has_segment_start) {
        segments.push_back({RoundMs(segment_start), step_ms});
      }
      hysteresis.Reset();
      has_segment_start = false;
      last_stable = false;
      continue;
    }

    // Click-driven "zoom wanted": a click within the hold window before now.
    while (click_index < clicks.size() && clicks[click_index].t_ms <= step_ms) {
      last_click_ms = clicks[click_index].t_ms;
      ++click_index;
    }
    const bool raw_wanted =
        last_click_ms >= 0 && (step_ms - last_click_ms) <= hold_ms;

    if (raw_wanted != last_raw) {
      raw_changed_at = time;
      last_raw = raw_wanted;
    }
    const bool stable = hysteresis.Update(time, raw_wanted);

    if (stable && !last_stable) {
      segment_start = raw_changed_at;
      has_segment_start = true;
    } else if (!stable && last_stable && has_segment_start) {
      segments.push_back({RoundMs(segment_start), RoundMs(raw_changed_at)});
      has_segment_start = false;
    }
    last_stable = stable;
  }
  if (has_segment_start && last_stable) {
    segments.push_back({RoundMs(segment_start), effective_ms});
  }

  // Merge segments separated by < kZoomTimelineGapMergeMs.
  std::vector<ZoomSegment> merged;
  for (const auto& seg : segments) {
    if (!merged.empty() &&
        (seg.start_ms - merged.back().end_ms) <
            clingfy::preview::kZoomTimelineGapMergeMs) {
      merged.back().end_ms = seg.end_ms;
    } else {
      merged.push_back(seg);
    }
  }

  // Clamp to [0, duration], drop anything shorter than the minimum (N frames at
  // the sim FPS — macOS: round((1000/fps) * 2) = 33ms at 60fps).
  const std::int64_t min_duration_ms = static_cast<std::int64_t>(std::llround(
      (1000.0 / fps) * clingfy::preview::kZoomTimelineMinSegmentFrames));
  std::vector<ZoomSegment> result;
  for (auto& seg : merged) {
    const std::int64_t start = std::max<std::int64_t>(0, seg.start_ms);
    const std::int64_t end = std::min<std::int64_t>(effective_ms, seg.end_ms);
    if (end - start >= min_duration_ms) {
      result.push_back({start, end});
    }
  }
  return result;
}

}  // namespace clingfy::capture
