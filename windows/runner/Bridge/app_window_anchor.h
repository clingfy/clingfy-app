#ifndef RUNNER_BRIDGE_APP_WINDOW_ANCHOR_H_
#define RUNNER_BRIDGE_APP_WINDOW_ANCHOR_H_

#include <windows.h>

namespace clingfy {

// Which display the recording chrome (pre-recording bar, recording indicator)
// should appear on.
//
// macOS resolves this with `NSScreen.main`, which is the screen holding the
// *key window* -- not the primary display. Windows has no direct equivalent, so
// the runner records the main Flutter window here at startup and the overlays
// resolve their monitor from it.
//
// Resolving from the overlay's own HWND instead is wrong: overlay windows are
// created at (0, 0) before they are ever positioned, so `MonitorFromWindow`
// always answers "primary". On a multi-monitor desktop that strands the chrome
// on the primary display while the user works on another one.

// Records the main Flutter window. Called once during startup, before any
// overlay is shown. Passing nullptr clears the registration.
void SetMainAppWindow(HWND hwnd);

// The registered main window, or nullptr if it was never set.
HWND MainAppWindow();

// Work area of the display that should anchor overlay chrome: the one showing
// the main app window. Falls back to `fallback`'s display and then the primary,
// so a missing registration degrades to the previous behavior rather than
// placing chrome at the origin.
RECT AnchorWorkArea(HWND fallback);

// Work area of the display holding `hwnd` (primary fallback). Use when a window
// must be clamped against the display it currently sits on -- for example the
// indicator after the user drags it to a second monitor, which must NOT be
// pulled back to the anchor display.
RECT WorkAreaForWindow(HWND hwnd);

// Work area of the display containing `pt` (primary fallback).
RECT WorkAreaForPoint(POINT pt);

}  // namespace clingfy

#endif  // RUNNER_BRIDGE_APP_WINDOW_ANCHOR_H_
