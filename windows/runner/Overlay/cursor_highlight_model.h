#ifndef RUNNER_OVERLAY_CURSOR_HIGHLIGHT_MODEL_H_
#define RUNNER_OVERLAY_CURSOR_HIGHLIGHT_MODEL_H_

#include <cstdint>
#include <vector>

// The live cursor highlight: a soft yellow disc that follows the pointer while
// recording, with an outline that pulses on each left click. Port of macOS
// `CursorHighlighter` + `CursorView` + `CursorHighlightCoordinator`.
//
// This file is the pure half (the show rule, the click pulse curve, and the
// pixels), unit-tested headless. The window and its thread live in
// cursor_highlight_overlay.*.
//
// The halo is meant to be RECORDED: like the macOS panel, the window is not
// excluded from capture, so it lands in the video as a visual aid. That is
// the point of it, and why it is drawn as a plain on-screen window rather
// than re-rendered at export like the cursor itself.
namespace clingfy::overlay {

// macOS CursorHighlightCoordinator.shouldShowCursor, with the per-session
// suppression folded in (effectiveCursorEnabledForRecording):
//   linked   -> only while a recording is running (not paused) and enabled
//   unlinked -> whenever enabled
// `session_disabled` is the startRecording request's disableCursorHighlight.
// It holds for the whole session, paused included, and the caller clears it
// when the session ends (macOS clearSessionSuppressions).
bool CursorHighlightShouldShow(bool enabled, bool linked,
                               bool actively_recording, bool session_disabled);

// macOS geometry, in points (DIPs): a 60 pt disc centred in a 120 pt window,
// and a click outline 2 pt outside it, 3 pt wide.
inline constexpr double kCursorHighlightRingDip = 60.0;
inline constexpr double kCursorHighlightWindowDip = 120.0;
inline constexpr double kCursorHighlightClickInsetDip = 2.0;
inline constexpr double kCursorHighlightClickStrokeDip = 3.0;
// The pulse: scale 1 -> 1.35 and opacity 1 -> 0 over 0.35 s, ease-out.
inline constexpr double kCursorHighlightPulseSeconds = 0.35;
inline constexpr double kCursorHighlightPulseMaxScale = 1.35;

struct CursorHighlightPulse {
  bool active = false;  // false before a click and once the pulse is over
  double scale = 1.0;
  double opacity = 0.0;
};

// The pulse `seconds_since_click` after a click. Negative = no click yet.
// CAMediaTimingFunction(.easeOut) is the cubic bezier (0,0)-(0.58,1); this
// solves it for the given time so the curve matches the Mac's.
CursorHighlightPulse CursorHighlightPulseAt(double seconds_since_click);

// The window's side in physical pixels for a monitor at `dpi` (96 = 100%).
int CursorHighlightWindowPx(unsigned dpi);

// Draw the highlight into a square premultiplied BGRA buffer of side
// `size_px` (row-major, top-down), cleared first. `scale` is dpi / 96.
// Anti-aliased by coverage. Colours are macOS systemYellow: the disc at 25%
// opacity, the click outline opaque times the pulse opacity.
void RasterizeCursorHighlight(std::vector<std::uint32_t>* bgra, int size_px,
                              double scale, const CursorHighlightPulse& pulse);

}  // namespace clingfy::overlay

#endif  // RUNNER_OVERLAY_CURSOR_HIGHLIGHT_MODEL_H_
