#ifndef RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_MODEL_H_
#define RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_MODEL_H_

#include <cstdint>
#include <string>

#include "Capture/recording_session_state.h"

// Slice 1 (Windows recording indicator): the pure, window-free logic behind the
// always-on-top recording pill. Kept separate from
// `recording_indicator_controller.*` (which owns the HWND / GDI / thread) so
// this half is unit-testable in headless CI with no window creation — mirroring
// how macOS split `RecordingIndicatorCoordinator` (pure) from
// `RecordingIndicator` (the AppKit panel).
namespace clingfy::capture {

// What the indicator should be showing, derived from the engine's recorder
// state. Mirrors macOS `IndicatorState` (RecordingIndicatorCoordinator.swift):
// idle / starting collapse to hidden — the pill is not shown until the
// recording is actually live.
enum class IndicatorVisualState {
  kHidden,
  kRecording,
  kPaused,
  kStopping,
};

// Pure mapping from the engine's `RecordingState` to the indicator's visual
// state. Verbatim parity with macOS `indicatorState(for:)`, extended for the
// two Windows-only transient states (`kResuming` reads as recording, `kPausing`
// as paused) and the two Windows-only terminal states (`kStopped` / `kFailed`
// collapse to hidden — the pill is gone once the session ends).
IndicatorVisualState IndicatorStateFor(RecordingState state);

// Zero-padded `HH:MM:SS` elapsed label. Parity with macOS
// `RecordingIndicatorCoordinator.formatElapsed(seconds:)`: each field is padded
// to at least two digits, hours are NOT capped (10h renders "10:00:04"), and a
// pre-start elapsed of 0 renders "00:00:00".
std::string FormatIndicatorElapsed(std::uint64_t seconds);

// Screen placement of the pill within a monitor's work area. The base size is
// in logical (96-dpi) pixels; the result is scaled by `scale` and inset from
// the TOP-RIGHT corner, then clamped so the pill always stays inside the work
// area (a work area smaller than the pill pins it to the top-left).
struct IndicatorRect {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
};

IndicatorRect ComputeIndicatorRect(int work_left, int work_top, int work_right,
                                   int work_bottom, double scale,
                                   int base_width, int base_height);

// Slice 2: the pill's interactive controls. The "primary" control is
// pause (when recording) or resume (when paused) — same rect, different glyph
// and different reverse call; the caller derives which from the visual state.
enum class IndicatorButton {
  kNone,
  kPrimary,  // pause (recording) OR resume (paused)
  kStop,
};

// A control rectangle in window client coordinates. `present` is false when the
// button is not shown for the current state (then the rect is degenerate).
struct IndicatorButtonRect {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;
  bool present = false;

  bool Contains(int x, int y) const {
    return present && x >= left && x < right && y >= top && y < bottom;
  }
};

struct IndicatorButtonLayout {
  IndicatorButtonRect primary;  // pause / resume
  IndicatorButtonRect stop;
};

// Lay out the right-aligned control buttons for the given client size + visual
// state. Buttons are square, vertically centered, and packed right-to-left:
// [ ...timer... ] [primary] [stop]. Only the recording / paused states get
// controls (hidden / stopping get none); the primary (pause/resume) button is
// omitted when `can_pause_resume` is false, mirroring macOS
// `isPrimaryActionAvailable`.
IndicatorButtonLayout ComputeIndicatorButtons(int client_width,
                                              int client_height,
                                              IndicatorVisualState state,
                                              bool can_pause_resume);

// Which control (if any) contains the client-coordinate point.
IndicatorButton HitTestIndicatorButton(const IndicatorButtonLayout& layout,
                                       int x, int y);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_INDICATOR_RECORDING_INDICATOR_MODEL_H_
