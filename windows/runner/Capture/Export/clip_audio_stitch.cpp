#include "Capture/Export/clip_audio_stitch.h"

#include <algorithm>

namespace clingfy::capture::export_::clip_audio {

namespace {

// Truncating ms -> per-channel frame conversion (§5.1: never round). Matches
// the video path's truncated frame_ms, so audio and video quantize the same
// millisecond boundaries the same way.
std::int64_t MsToFrames(std::int64_t ms, std::int64_t sample_rate_hz) {
  return (ms * sample_rate_hz) / 1000;
}

}  // namespace

std::vector<AudioCopySpan> PlanKeptAudioCopies(
    std::int64_t packet_src_start_frame, std::uint32_t packet_frame_count,
    const std::vector<clip_planner::ClipKeptRange>& ranges,
    std::int64_t sample_rate_hz) {
  std::vector<AudioCopySpan> spans;
  if (packet_frame_count == 0 || sample_rate_hz <= 0) {
    return spans;
  }

  const std::int64_t packet_start = packet_src_start_frame;
  const std::int64_t packet_end =
      packet_src_start_frame + static_cast<std::int64_t>(packet_frame_count);

  // No clips: pass the whole packet through 1:1 (source frame == edited frame),
  // so the writer behaves exactly as it did before cuts.
  if (ranges.empty()) {
    spans.push_back(AudioCopySpan{
        /*edited_start_frame=*/packet_start,
        /*src_offset_frames=*/0,
        /*frame_count=*/packet_frame_count,
    });
    return spans;
  }

  // Walk kept ranges in timeline order. The edited base of a range is the
  // truncated cumulative edited-ms duration of the earlier ranges, converted to
  // frames — the SAME instant the video re-stamp lands the range's first frame
  // on (video: base_ms * 10^4 hns; audio: base_ms * sr / 1000 frames), so audio
  // and video seams align at every range boundary. Each range's source window
  // is intersected with the packet; the intersection is copied verbatim and
  // re-stamped by its offset from the range start.
  std::int64_t base_ms = 0;
  for (const clip_planner::ClipKeptRange& r : ranges) {
    const std::int64_t range_in_frame =
        MsToFrames(r.source_in_ms, sample_rate_hz);
    const std::int64_t range_out_frame =
        MsToFrames(r.source_out_ms, sample_rate_hz);
    const std::int64_t edited_base_frame = MsToFrames(base_ms, sample_rate_hz);
    base_ms += r.DurationMs();

    const std::int64_t i0 = std::max(packet_start, range_in_frame);
    const std::int64_t i1 = std::min(packet_end, range_out_frame);
    if (i1 <= i0) {
      continue;  // no overlap with this kept range
    }

    spans.push_back(AudioCopySpan{
        /*edited_start_frame=*/edited_base_frame + (i0 - range_in_frame),
        /*src_offset_frames=*/static_cast<std::uint32_t>(i0 - packet_start),
        /*frame_count=*/static_cast<std::uint32_t>(i1 - i0),
    });
  }
  return spans;
}

std::vector<ReorderAudioSlot> PlanReorderAudioSlots(
    const std::vector<clip_planner::AudioSlot>& slots,
    std::int64_t sample_rate_hz) {
  std::vector<ReorderAudioSlot> out;
  if (sample_rate_hz <= 0) {
    return out;
  }
  out.reserve(slots.size());
  for (const clip_planner::AudioSlot& s : slots) {
    // Derive the slot's frame span from a cumulative-ms→frame conversion of its
    // edited placement — NOT by summing per-slot frame counts — so slot N's end
    // frame is exactly slot N+1's start frame at any sample rate (the same
    // tiling the monotonic path's `edited_base_frame` uses).
    const std::int64_t start_frame =
        MsToFrames(s.edited_start_ms, sample_rate_hz);
    const std::int64_t end_frame =
        MsToFrames(s.edited_start_ms + s.duration_ms, sample_rate_hz);
    const std::int64_t slot_frames = std::max<std::int64_t>(0, end_frame - start_frame);
    // copy_duration_ms is already clamped to the audio extent (<= duration_ms)
    // by AudioSlots; clamp again defensively so copy never exceeds the slot.
    const std::int64_t copy_frames = std::min(
        std::max<std::int64_t>(0, MsToFrames(s.copy_duration_ms, sample_rate_hz)),
        slot_frames);
    out.push_back(ReorderAudioSlot{
        /*source_in_frame=*/MsToFrames(s.source_in_ms, sample_rate_hz),
        /*edited_start_frame=*/start_frame,
        /*copy_frame_count=*/copy_frames,
        /*silence_frame_count=*/slot_frames - copy_frames,
    });
  }
  return out;
}

PumpCursor PrimeReorderCursor(const std::vector<ReorderAudioSlot>& plan,
                              std::int64_t edited_frame) {
  PumpCursor cursor;
  if (plan.empty() || edited_frame <= 0) {
    // Empty plan: slot_index 0 == plan.size(), which reads as "done".
    // Negative/zero target: start of the timeline.
    return cursor;
  }
  // Slots tile the edited timeline contiguously and plans are tiny (one slot
  // per kept range) — a linear scan is the clearest correct thing.
  for (std::size_t i = 0; i < plan.size(); ++i) {
    const ReorderAudioSlot& p = plan[i];
    const std::int64_t slot_frames = p.copy_frame_count + p.silence_frame_count;
    if (edited_frame < p.edited_start_frame + slot_frames) {
      cursor.slot_index = i;
      cursor.emitted_frames =
          std::max<std::int64_t>(0, edited_frame - p.edited_start_frame);
      return cursor;
    }
  }
  cursor.slot_index = plan.size();
  cursor.emitted_frames = 0;
  return cursor;
}

}  // namespace clingfy::capture::export_::clip_audio
