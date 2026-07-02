// Editing-features port (clips) — pure clip cut/arrange timeline math.
//
// This unit is a faithful C++ port of the macOS `ClipPlaybackPlanner` +
// `ClipKeptRange` (macos/Runner/Capture/Export/CompositionBuilder.swift),
// tested by the same suite as macOS `ClipPlaybackPlannerTests`. It is the
// timeline↔source map every clip feature hangs off — export bake, live
// preview, and the source-time-keyed overlays (zoom, cursor, camera) all
// remap through these functions or silently desync
// (docs/windows-port-editing-features.md §2, §4).
//
// Swift → C++ name map:
//   ClipKeptRange                      → ClipKeptRange
//   Decision (.proceed/.advance/.end)  → PlaybackDecision (Kind + payload)
//   isPassthrough(ranges:assetDurationMs:) → IsPassthrough
//   decide(sourceMs:activeIndex:ranges:epsilonMs:) → Decide
//   activeIndex(forSourceMs:ranges:)   → ActiveIndexForSourceMs
//   activeIndex(forEditedMs:ranges:)   → ActiveIndexForEditedMs
//   editedDurationMs(ranges:)          → EditedDurationMs
//   editedMs(forSourceMs:activeIndex:ranges:) → EditedMsForSourceMs
//   sourceMs(forEditedMs:ranges:)      → SourceMsForEditedMs
//   editedMsForKeptSourceMs(_:ranges:) → EditedMsForKeptSourceMs
//   coalesce(ranges:)                  → Coalesce
//   isSourceMonotonic(_:)              → IsSourceMonotonic
//   isAtEnd(sourceMs:ranges:epsilonMs:) → IsAtEnd
//   AudioSlot / audioSlots(ranges:audioDurationMs:) → AudioSlot / AudioSlots
//
// Load-bearing invariants carried over from the macOS lessons
// (docs/windows-port-editing-features.md §5):
//   * §5.1 every seconds→ms conversion in the clip path TRUNCATES, never
//     rounds — a 1 ms rounding drift makes IsPassthrough misreport an
//     unedited recording as cut. All values here are already int ms.
//   * §5.2 audio slots advance by each range's FULL duration, not the
//     copied length — a clamped/absent range mid-timeline under reorder
//     must leave silence inside its own slot, not pull later audio earlier.
//   * §5.3 reorder (arrange) produces non-monotonic source ranges; the
//     export writer must not assume a single forward read. Use
//     IsSourceMonotonic to pick the path.
//
// Everything here is pure (no Win32, no Media Foundation, no Flutter
// headers). Parsing the Dart `Clip.toMap()` payload into ClipKeptRange
// lives with the routers (the export_router precedent), not here.
//
// Keep this in sync with the Swift planner: behavior changes land on both
// platforms in the same change or not at all.

#ifndef RUNNER_CAPTURE_EXPORT_CLIP_PLAYBACK_PLANNER_H_
#define RUNNER_CAPTURE_EXPORT_CLIP_PLAYBACK_PLANNER_H_

#include <cstdint>
#include <optional>
#include <vector>

namespace clingfy::capture::export_::clip_planner {

// A kept source range on the edited timeline, listed in TIMELINE order. Cut
// regions are simply the gaps between consecutive ranges' source windows.
// Mirrors the Dart `Clip` (enabled clips only); the Dart side normalizes the
// list so timeline positions tile contiguously from zero, so the native side
// only needs the source windows in order.
struct ClipKeptRange {
  std::int64_t source_in_ms = 0;
  std::int64_t source_out_ms = 0;

  std::int64_t DurationMs() const {
    const std::int64_t d = source_out_ms - source_in_ms;
    return d > 0 ? d : 0;
  }

  friend bool operator==(const ClipKeptRange& a, const ClipKeptRange& b) {
    return a.source_in_ms == b.source_in_ms &&
           a.source_out_ms == b.source_out_ms;
  }
  friend bool operator!=(const ClipKeptRange& a, const ClipKeptRange& b) {
    return !(a == b);
  }
};

// The planner's per-tick playback decision. Mirrors the Swift
// `ClipPlaybackPlanner.Decision` enum with associated values.
struct PlaybackDecision {
  enum class Kind {
    kProceed,  // Keep playing — still inside the active kept range.
    kAdvance,  // Jump to the next kept range (a cut boundary was reached).
    kEnd,      // Reached the end of the edited timeline — stop.
  };

  Kind kind = Kind::kProceed;
  // Valid only when kind == kAdvance.
  int to_index = 0;
  std::int64_t seek_source_ms = 0;

  static PlaybackDecision Proceed() { return {Kind::kProceed, 0, 0}; }
  static PlaybackDecision Advance(int to_index, std::int64_t seek_source_ms) {
    return {Kind::kAdvance, to_index, seek_source_ms};
  }
  static PlaybackDecision End() { return {Kind::kEnd, 0, 0}; }

  friend bool operator==(const PlaybackDecision& a, const PlaybackDecision& b) {
    if (a.kind != b.kind) return false;
    if (a.kind != Kind::kAdvance) return true;
    return a.to_index == b.to_index && a.seek_source_ms == b.seek_source_ms;
  }
  friend bool operator!=(const PlaybackDecision& a, const PlaybackDecision& b) {
    return !(a == b);
  }
};

// One kept range's placement in the edited-timeline audio composition. The
// slot begins at `edited_start_ms` (the cumulative FULL duration of the
// earlier ranges — the same offset the video re-stamp uses) and spans the
// range's full `duration_ms`. Only `copy_duration_ms` of real source audio
// is available from `source_in_ms` — the captured audio track can run
// shorter than the video — and the rest of the slot is silence. See the
// §5.2 invariant in the header comment.
struct AudioSlot {
  std::int64_t source_in_ms = 0;
  std::int64_t edited_start_ms = 0;
  std::int64_t copy_duration_ms = 0;
  std::int64_t duration_ms = 0;

  friend bool operator==(const AudioSlot& a, const AudioSlot& b) {
    return a.source_in_ms == b.source_in_ms &&
           a.edited_start_ms == b.edited_start_ms &&
           a.copy_duration_ms == b.copy_duration_ms &&
           a.duration_ms == b.duration_ms;
  }
  friend bool operator!=(const AudioSlot& a, const AudioSlot& b) {
    return !(a == b);
  }
};

// True when the ranges need no skipping: absent, or a single window that
// already covers the whole asset from 0. Lets the caller skip all planner
// work (a zero-cost passthrough, like an identity color grade).
bool IsPassthrough(const std::vector<ClipKeptRange>& ranges,
                   std::int64_t asset_duration_ms);

// From the current player source position and the active range index, decide
// whether to keep playing, jump to the next range, or stop. `epsilon_ms`
// absorbs the periodic observer's overshoot so the jump fires a hair before
// the exact cut instead of flashing a frame of cut footage.
PlaybackDecision Decide(std::int64_t source_ms, int active_index,
                        const std::vector<ClipKeptRange>& ranges,
                        std::int64_t epsilon_ms = 0);

// The active range index for a source position: the range containing it,
// else the first range starting after it, else the last. Used when the clip
// list changes or the user seeks.
int ActiveIndexForSourceMs(std::int64_t source_ms,
                           const std::vector<ClipKeptRange>& ranges);

// The kept-range index that an edited-timeline position falls in — the
// inverse counterpart to ActiveIndexForSourceMs. A position at or past the
// edited end resolves to the last range. Used when the user seeks/scrubs on
// the edited timeline so the active range is refreshed to match.
int ActiveIndexForEditedMs(std::int64_t edited_ms,
                           const std::vector<ClipKeptRange>& ranges);

// Total edited-timeline duration (sum of kept range durations).
std::int64_t EditedDurationMs(const std::vector<ClipKeptRange>& ranges);

// Maps a real source position to its edited-timeline position given the
// active range index (handles arrange, where source order need not match
// timeline order): the durations of all preceding ranges plus the offset
// into the active range.
std::int64_t EditedMsForSourceMs(std::int64_t source_ms, int active_index,
                                 const std::vector<ClipKeptRange>& ranges);

// Maps an edited-timeline position back to a real source position — the
// inverse of EditedMsForSourceMs. A position past the edited end parks on
// the last kept frame. This is what lets a seek/scrub on the edited timeline
// land on the correct source frame across cuts (and, paired with
// ActiveIndexForEditedMs, stops a backward seek from parking the playhead at
// the cut).
std::int64_t SourceMsForEditedMs(std::int64_t edited_ms,
                                 const std::vector<ClipKeptRange>& ranges);

// The edited-timeline position for a source moment that lies strictly inside
// a kept range, or nullopt when the moment was removed by a cut. This is
// what the export writer uses to drive "cut at the writer": for each source
// frame it pulls, nullopt means drop the frame (it is in a cut gap), and a
// value means re-stamp the frame onto the compacted edited timeline at that
// position. Unlike EditedMsForSourceMs it never clamps a cut-gap moment to a
// boundary — a dropped frame must be reported as dropped, not snapped to the
// edge.
//
// Empty `ranges` is a passthrough (no cuts): every source moment is kept and
// maps to itself, so the writer behaves exactly as it did before cuts.
std::optional<std::int64_t> EditedMsForKeptSourceMs(
    std::int64_t source_ms, const std::vector<ClipKeptRange>& ranges);

// Merges source-adjacent kept ranges (where range[i].source_out_ms ==
// range[i+1].source_in_ms) into one. A split with no deletion produces
// contiguous ranges that cover the asset with no removed footage; coalescing
// turns that back into a single passthrough range so playback and seeking
// skip all clip handling. Reordered (arrange) ranges are not source-adjacent,
// so they are left intact.
std::vector<ClipKeptRange> Coalesce(const std::vector<ClipKeptRange>& ranges);

// True when the kept ranges are listed in non-decreasing source order, i.e.
// reading the source asset forward yields frames in edited-timeline order.
// "Cut at the writer" forward-reads the source once and re-stamps kept
// frames onto the compacted timeline, so it requires this property to emit a
// monotonically increasing output PTS. Split / cut / trim always preserve it
// (timeline order == source order); only clip *reorder* (arrange) can break
// it, and reorder export is handled separately by the caller (§5.3).
bool IsSourceMonotonic(const std::vector<ClipKeptRange>& ranges);

// True when a source position sits at/after the last kept range's end
// (within `epsilon_ms`) — i.e. the player is parked at the edited end, the
// spot where playback completes. Used so play() restarts from the beginning
// instead of no-op'ing on the last frame.
bool IsAtEnd(std::int64_t source_ms, const std::vector<ClipKeptRange>& ranges,
             std::int64_t epsilon_ms = 0);

// Tiles the kept ranges (in timeline order) into edited-timeline audio
// slots, clamping each range's copied length to what a source audio track of
// `audio_duration_ms` actually covers. The slots tile [0, EditedDurationMs)
// contiguously regardless of source order.
std::vector<AudioSlot> AudioSlots(const std::vector<ClipKeptRange>& ranges,
                                  std::int64_t audio_duration_ms);

}  // namespace clingfy::capture::export_::clip_planner

#endif  // RUNNER_CAPTURE_EXPORT_CLIP_PLAYBACK_PLANNER_H_
