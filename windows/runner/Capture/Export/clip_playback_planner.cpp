#include "Capture/Export/clip_playback_planner.h"

#include <algorithm>

namespace clingfy::capture::export_::clip_planner {

namespace {

// Clamps a caller-supplied active index into [0, count - 1], mirroring the
// Swift `min(max(activeIndex, 0), ranges.count - 1)`. Callers may pass a
// stale index after the clip list shrinks.
int ClampIndex(int index, std::size_t count) {
  const int last = static_cast<int>(count) - 1;
  return std::min(std::max(index, 0), last);
}

}  // namespace

bool IsPassthrough(const std::vector<ClipKeptRange>& ranges,
                   std::int64_t asset_duration_ms) {
  if (ranges.empty()) return true;
  if (ranges.size() != 1) return false;
  const ClipKeptRange& only = ranges[0];
  return only.source_in_ms <= 0 && only.source_out_ms >= asset_duration_ms;
}

PlaybackDecision Decide(std::int64_t source_ms, int active_index,
                        const std::vector<ClipKeptRange>& ranges,
                        std::int64_t epsilon_ms) {
  if (ranges.empty()) return PlaybackDecision::Proceed();
  const int idx = ClampIndex(active_index, ranges.size());
  const ClipKeptRange& active = ranges[idx];
  if (source_ms < active.source_out_ms - epsilon_ms) {
    return PlaybackDecision::Proceed();
  }
  const int next_index = idx + 1;
  if (next_index < static_cast<int>(ranges.size())) {
    return PlaybackDecision::Advance(next_index,
                                     ranges[next_index].source_in_ms);
  }
  return PlaybackDecision::End();
}

int ActiveIndexForSourceMs(std::int64_t source_ms,
                           const std::vector<ClipKeptRange>& ranges) {
  if (ranges.empty()) return 0;
  for (std::size_t i = 0; i < ranges.size(); ++i) {
    if (source_ms >= ranges[i].source_in_ms &&
        source_ms < ranges[i].source_out_ms) {
      return static_cast<int>(i);
    }
  }
  for (std::size_t i = 0; i < ranges.size(); ++i) {
    if (source_ms < ranges[i].source_in_ms) {
      return static_cast<int>(i);
    }
  }
  return static_cast<int>(ranges.size()) - 1;
}

int ActiveIndexForEditedMs(std::int64_t edited_ms,
                           const std::vector<ClipKeptRange>& ranges) {
  if (ranges.empty()) return 0;
  const std::int64_t target = std::max<std::int64_t>(0, edited_ms);
  std::int64_t base = 0;
  for (std::size_t i = 0; i < ranges.size(); ++i) {
    if (target < base + ranges[i].DurationMs()) {
      return static_cast<int>(i);
    }
    base += ranges[i].DurationMs();
  }
  return static_cast<int>(ranges.size()) - 1;
}

std::int64_t EditedDurationMs(const std::vector<ClipKeptRange>& ranges) {
  std::int64_t total = 0;
  for (const ClipKeptRange& r : ranges) total += r.DurationMs();
  return total;
}

std::int64_t EditedMsForSourceMs(std::int64_t source_ms, int active_index,
                                 const std::vector<ClipKeptRange>& ranges) {
  if (ranges.empty()) return source_ms;
  const int idx = ClampIndex(active_index, ranges.size());
  std::int64_t base = 0;
  for (int i = 0; i < idx; ++i) base += ranges[i].DurationMs();
  const std::int64_t offset =
      std::max<std::int64_t>(0, source_ms - ranges[idx].source_in_ms);
  return base + std::min(offset, ranges[idx].DurationMs());
}

std::int64_t SourceMsForEditedMs(std::int64_t edited_ms,
                                 const std::vector<ClipKeptRange>& ranges) {
  if (ranges.empty()) return edited_ms;
  const std::int64_t target = std::max<std::int64_t>(0, edited_ms);
  std::int64_t base = 0;
  for (const ClipKeptRange& r : ranges) {
    if (target < base + r.DurationMs()) {
      return r.source_in_ms + (target - base);
    }
    base += r.DurationMs();
  }
  return ranges.back().source_out_ms;
}

std::optional<std::int64_t> EditedMsForKeptSourceMs(
    std::int64_t source_ms, const std::vector<ClipKeptRange>& ranges) {
  if (ranges.empty()) return source_ms;
  std::int64_t base = 0;
  for (const ClipKeptRange& r : ranges) {
    if (source_ms >= r.source_in_ms && source_ms < r.source_out_ms) {
      return base + (source_ms - r.source_in_ms);
    }
    base += r.DurationMs();
  }
  return std::nullopt;
}

std::vector<ClipKeptRange> Coalesce(const std::vector<ClipKeptRange>& ranges) {
  if (ranges.size() <= 1) return ranges;
  std::vector<ClipKeptRange> out;
  for (const ClipKeptRange& r : ranges) {
    if (!out.empty() && out.back().source_out_ms == r.source_in_ms) {
      out.back().source_out_ms = r.source_out_ms;
    } else {
      out.push_back(r);
    }
  }
  return out;
}

bool IsSourceMonotonic(const std::vector<ClipKeptRange>& ranges) {
  if (ranges.size() <= 1) return true;
  for (std::size_t i = 1; i < ranges.size(); ++i) {
    if (ranges[i].source_in_ms < ranges[i - 1].source_in_ms) return false;
  }
  return true;
}

bool IsAtEnd(std::int64_t source_ms, const std::vector<ClipKeptRange>& ranges,
             std::int64_t epsilon_ms) {
  if (ranges.empty()) return false;
  return source_ms >= ranges.back().source_out_ms - epsilon_ms;
}

std::vector<AudioSlot> AudioSlots(const std::vector<ClipKeptRange>& ranges,
                                  std::int64_t audio_duration_ms) {
  const std::int64_t audio_ms = std::max<std::int64_t>(0, audio_duration_ms);
  std::int64_t base = 0;
  std::vector<AudioSlot> slots;
  slots.reserve(ranges.size());
  for (const ClipKeptRange& r : ranges) {
    const std::int64_t copy_end_ms = std::min(r.source_out_ms, audio_ms);
    const std::int64_t copy_ms =
        std::max<std::int64_t>(0, copy_end_ms - r.source_in_ms);
    slots.push_back(AudioSlot{
        /*source_in_ms=*/r.source_in_ms,
        /*edited_start_ms=*/base,
        /*copy_duration_ms=*/copy_ms,
        /*duration_ms=*/r.DurationMs(),
    });
    base += r.DurationMs();
  }
  return slots;
}

}  // namespace clingfy::capture::export_::clip_planner
