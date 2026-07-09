#ifndef RUNNER_CAPTURE_EXPORT_CLIP_AUDIO_STITCH_H_
#define RUNNER_CAPTURE_EXPORT_CLIP_AUDIO_STITCH_H_

#include <cstdint>
#include <vector>

#include "Capture/Export/clip_playback_planner.h"

// Sample-accurate audio stitching for clip export (editing Step 3b-1).
//
// Step 3a kept or dropped whole decoded audio packets by their START time,
// which leaked up to ~21 ms of cut-adjacent audio at each seam
// (docs/windows-port-editing-features.md §5.2, and the note in
// export_pipeline.cpp). This unit maps a decoded audio packet onto the edited
// timeline SAMPLE-accurately: a packet straddling a cut is trimmed to the exact
// frame at the boundary, and a packet that spans a cut can contribute to two
// adjacent kept ranges (the leading audio of the range after the cut is no
// longer dropped).
//
// Pure integer-frame math — no Media Foundation, no Flutter — so the seam
// behavior is unit-tested headlessly (the export is the deterministic,
// headless-testable half; §6). Every ms->frame conversion TRUNCATES (§5.1).
//
// Scope: this is the MONOTONIC + disjoint (forward-read) case, which is all the
// export writer routes here today. Reorder's per-slot seek + explicit
// silence-fill (§5.2/§5.3) lands in Step 3b-2. Because it maps each source
// moment to the first kept range that contains it, it is well-defined only for
// disjoint ranges (overlap is refused upstream until 3b-2).
//
// "Frame" == one per-channel sample instant (48 kHz stereo => 48 frames/ms).

namespace clingfy::capture::export_::clip_audio {

// One contiguous run of source-audio frames to copy onto the edited timeline.
struct AudioCopySpan {
  // Destination: the run's first frame, as a per-channel index on the edited
  // timeline. Convert to a media timestamp with (frame * 10^7 / sample_rate).
  std::int64_t edited_start_frame = 0;
  // Source: offset (in frames) into the decoded packet where the run begins.
  std::uint32_t src_offset_frames = 0;
  // Length of the run, in frames.
  std::uint32_t frame_count = 0;
};

// Plan the sample-accurate copies for one decoded audio packet.
//
// `packet_src_start_frame` is the packet's first frame on the SOURCE audio
// timeline (per-channel frame index, recording-relative — the same zero the
// clip ranges use). `ranges` are the kept source windows in timeline order.
//
// Returns the runs of the packet that fall inside kept ranges, each re-stamped
// to its edited-timeline frame; frames inside a cut gap are omitted. For
// monotonic ranges the spans come back in increasing edited order (so the
// caller can write them straight to an encoder that requires monotonic audio
// timestamps). Empty `ranges` is a passthrough: one span mapping the whole
// packet 1:1.
std::vector<AudioCopySpan> PlanKeptAudioCopies(
    std::int64_t packet_src_start_frame, std::uint32_t packet_frame_count,
    const std::vector<clip_planner::ClipKeptRange>& ranges,
    std::int64_t sample_rate_hz);

}  // namespace clingfy::capture::export_::clip_audio

#endif  // RUNNER_CAPTURE_EXPORT_CLIP_AUDIO_STITCH_H_
