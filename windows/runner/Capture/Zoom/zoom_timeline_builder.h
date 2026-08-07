#ifndef RUNNER_CAPTURE_ZOOM_ZOOM_TIMELINE_BUILDER_H_
#define RUNNER_CAPTURE_ZOOM_ZOOM_TIMELINE_BUILDER_H_

#include <cstdint>
#include <vector>

#include "Capture/Cursor/cursor_sidecar_reader.h"

// Phase 8.3 — structural port of macOS `ZoomTimelineBuilder.swift`.
//
// Generates auto-zoom segments by simulating the cursor at a fixed FPS, stepping
// `ZoomHysteresis` once per simulated frame, and emitting [startMs,endMs] spans,
// then merging tiny gaps and dropping sub-minimum segments.
//
// DIVERGENCE FROM macOS: macOS's per-frame "zoom wanted" is `spriteID !=
// defaultSpriteID` (the cursor changed shape). Windows has no cursor-shape data
// (Phase 8.1 deferred sprite capture), so it uses a CLICK-driven signal instead:
// zoom is wanted while a click occurred within `kZoomClickHoldSeconds`. The
// in-bounds gate (cursor visible) and all the hysteresis / merge / min-length
// machinery are identical to macOS.
namespace clingfy::capture {

struct ZoomSegment {
  std::int64_t start_ms = 0;
  std::int64_t end_ms = 0;
};

// How long a click keeps zoom "wanted". Windows-specific (macOS uses the
// continuous sprite signal and has no equivalent hold). Must exceed the
// hysteresis zoom-in delay (0.2s) or a lone click would never sustain long
// enough to trigger; 1.5s gives a single click a ~1.6s zoom and lets
// consecutive clicks extend it.
inline constexpr double kZoomClickHoldSeconds = 1.5;

// Build auto-zoom segments from the sidecar's cursor samples + click times.
// `duration_ms` is the recording length (0 → derived from the last sample/click).
// `fps` is the simulation rate (default = kZoomTimelineSimulationFPS).
// Returns [] when there are no samples or no clicks (→ no zoom).
std::vector<ZoomSegment> BuildZoomSegments(
    const std::vector<CursorSidecarSample>& samples,
    const std::vector<CursorSidecarClick>& clicks, std::int64_t duration_ms,
    double fps = 0.0, double click_hold_seconds = kZoomClickHoldSeconds);

// Whether `source_ms` falls inside a zoom segment, and how far into it.
//
// THE one definition of "a zoom is active right now", shared by the export and
// the inline preview. Both surfaces must resolve activation from the same
// segments in the same time base or anything keyed to it drifts — which is
// exactly what the camera zoom-emphasis pulse is: a 2 Hz throb whose phase is
// `local_ms`. At 2 Hz, 250 ms of disagreement is 180 degrees, i.e. the editor
// showing the bubble shrink where the export shows it grow.
//
// Membership is half-open [start_ms, end_ms), matching the export's own
// lookup: at end_ms the segment is over and the zoom target drops to 1.0 the
// same frame (the visible ease-out afterwards is the smoother catching up, not
// a still-active segment).
//
// `source_ms` is SOURCE time on both legs. Segments are built from
// source-keyed cursor clicks, so they cannot be looked up in edited time
// without first projecting them through the clip list.
struct ZoomSegmentState {
  bool in_segment = false;
  std::int64_t local_ms = 0;  // ms since the active segment's start_ms
};
ZoomSegmentState ZoomSegmentStateAt(const std::vector<ZoomSegment>& segments,
                                    std::int64_t source_ms);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_ZOOM_ZOOM_TIMELINE_BUILDER_H_
