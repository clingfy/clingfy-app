#ifndef RUNNER_OVERLAY_AREA_REVEAL_OVERLAY_H_
#define RUNNER_OVERLAY_AREA_REVEAL_OVERLAY_H_

#include <windows.h>

#include <cstdint>
#include <vector>

// "Reveal area": a white outline drawn around the selected recording area for
// one second, so the user can see what will be recorded. Port of macOS
// `AreaPreviewOverlay` (AreaSelectionOverlay.swift): shown by
// revealAreaRecordingRegion and right after a pick, hidden on clear and when
// a recording starts.
//
// macOS strokes a 2 pt line centred on the area's edge. Here the window is the
// area grown by the line's outer half on every side and kept on the area's
// monitor, and the line runs along the window's edges: centred on the area's
// edge, except against a monitor edge, where it falls just inside the area
// rather than off the screen (or onto the next monitor). Click-through,
// per-pixel alpha, only the frame opaque.
namespace clingfy::overlay {

inline constexpr double kAreaRevealLineDip = 2.0;
inline constexpr UINT kAreaRevealAutoHideMs = 1000;

struct AreaRevealFrame {
  RECT window{};    // screen coordinates (physical px); empty = nothing to show
  int line_px = 0;  // the outline's width, along the window's edges
};

// Where the outline window goes for an area given in monitor-local physical
// pixels on a monitor whose screen rect is `monitor`, at `dpi`. The area is
// clamped to the monitor first, as the recording clamps it; an area that
// misses the monitor entirely yields an empty window.
AreaRevealFrame ComputeAreaRevealFrame(const RECT& monitor, std::int32_t x,
                                       std::int32_t y, std::int32_t width,
                                       std::int32_t height, unsigned dpi);

// The window's pixels: premultiplied BGRA, top-down, opaque white in a
// `line_px` band along every edge, clear inside.
void RasterizeAreaRevealFrame(std::vector<std::uint32_t>* bgra, int width,
                              int height, int line_px);

// Show the outline for the CURRENT selection (WindowsSelectionState) and hide
// it after kAreaRevealAutoHideMs. A no-op without a selection or when its
// monitor is gone. Platform thread only (the window lives on the Flutter
// message loop). Showing again replaces the outline and restarts the timer.
void ShowAreaReveal();
void HideAreaReveal();

// Test / diagnostics.
bool IsAreaRevealShownForTesting();
RECT AreaRevealWindowRectForTesting();

}  // namespace clingfy::overlay

#endif  // RUNNER_OVERLAY_AREA_REVEAL_OVERLAY_H_
