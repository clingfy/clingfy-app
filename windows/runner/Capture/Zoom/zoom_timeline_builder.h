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

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_ZOOM_ZOOM_TIMELINE_BUILDER_H_
