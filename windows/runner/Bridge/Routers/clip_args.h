// Editing-features port (clips) — the ONE wire parser for the Dart
// `Clip.toMap()` list.
//
// Mirrors the macOS `ClipKeptRange.fromFlutter` exactly: disabled clips and
// non-positive source windows are dropped, timeline order is preserved, and
// numeric coercion accepts int or double (truncating, never rounding — the
// §5.1 rule). `id` and `timelineStartMs` are deliberately ignored: the Dart
// side normalizes the list so timeline positions tile contiguously, so the
// native side only needs the source windows in order.
//
// Consumers: export_router today (feeding the clip export bake — cut / trim /
// reorder / overlap); `previewSetClips` (step 4) will reuse this same parser
// — one wire shape, one parser, per the color_grade_args precedent.

#ifndef RUNNER_BRIDGE_ROUTERS_CLIP_ARGS_H_
#define RUNNER_BRIDGE_ROUTERS_CLIP_ARGS_H_

#include <flutter/encodable_value.h>

#include <vector>

#include "Capture/Export/clip_playback_planner.h"

namespace clingfy::bridge {

// Parses the VALUE of a `clips` entry (a list of Dart `Clip.toMap()` maps).
// nullptr or a non-list value yields an empty vector (no clip handling).
std::vector<capture::export_::clip_planner::ClipKeptRange> ParseClipRanges(
    const flutter::EncodableValue* value);

// Convenience: looks up `args["clips"]` and parses it. Missing key → empty.
std::vector<capture::export_::clip_planner::ClipKeptRange> ReadClipRangesArg(
    const flutter::EncodableMap& args);

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_ROUTERS_CLIP_ARGS_H_
