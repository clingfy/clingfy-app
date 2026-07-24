#ifndef RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_MODEL_H_
#define RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_MODEL_H_

#include <array>

// Slice 4 (Windows pre-recording bar): the pure, window-free logic behind the
// floating control bar shown BEFORE (and during) a recording — record button,
// source pickers, mic/camera/system toggles, update, pause/resume. Kept
// separate from `pre_recording_bar_controller.*` (which owns the HWND / GDI /
// thread) so this half is unit-testable in headless CI with no window creation,
// mirroring how the recording indicator split `recording_indicator_model` from
// `_controller`.
//
// macOS reference: `Overlays/PreRecordingBar/PreRecordingBarView.swift` for the
// state->style mapping + stack order, and `MainFlutterWindow`
// `shouldShowPreRecordingBar` for the phase visibility gate.
namespace clingfy::capture {

// The buttons the bar can render, in left-to-right stack order (parity with the
// macOS `PreRecordingBarView` stack: close | display window area | camera mic
// system pause-resume record update). `kNone` is a hit-test miss sentinel.
enum class BarButtonId {
  kNone,
  kClose,
  kDisplay,
  kWindow,
  kArea,
  kCamera,
  kMic,
  kSystemAudio,
  kPauseResume,
  kRecord,
  kUpdate,
};

// Number of real buttons (excludes `kNone`). The spec/layout arrays are indexed
// 0..kBarButtonCount-1 in the stack order above (kClose == 0, kUpdate == last).
inline constexpr int kBarButtonCount = 10;

// The ordered button ids that index the spec/layout arrays.
inline constexpr std::array<BarButtonId, kBarButtonCount> kBarButtonOrder = {
    BarButtonId::kClose,       BarButtonId::kDisplay, BarButtonId::kWindow,
    BarButtonId::kArea,        BarButtonId::kCamera,  BarButtonId::kMic,
    BarButtonId::kSystemAudio, BarButtonId::kPauseResume,
    BarButtonId::kRecord,      BarButtonId::kUpdate,
};

// Visual treatment of a button. `kSelected` = accent-tinted (the active capture
// source, or an enabled toggle); `kDisabled` = dimmed + non-interactive
// (phase-gated). Parity with macOS `applyButtonPresentation` tinting.
enum class BarButtonStyle { kNormal, kSelected, kDisabled };

// What the record button draws: the record dot (idle), the stop square
// (recording / paused), or a busy spinner (starting / stopping / finalizing).
// Parity with macOS record button `updateState` branches.
enum class RecordGlyph { kRecord, kStop, kBusy };

// The parsed, engine-agnostic inputs the bar renders from — the subset of the
// Dart `setPreRecordingBarState` map that the VIEW consumes. The ids used only
// by the Slice 6 native pickers (`selectedDisplayId`, `selectedAppWindowId`,
// `selectedAudioSourceId`, `selectedCamId`) are intentionally NOT here; this
// struct is only what render needs.
struct PreRecordingBarInputs {
  int phase = 0;         // WorkflowPhase wire value, 0..10 (idle..exporting).
  int target_mode = 0;   // DisplayTargetMode index: 0 display, 2 window, 3 area.
  bool camera_selected = false;       // a camera source is chosen.
  bool mic_enabled = false;           // a mic source is chosen (not "no audio").
  bool system_audio_enabled = false;  // system-audio capture toggled on.
  bool update_available = false;      // an app update is ready (shows Update).
  bool can_pause_resume = false;      // backend offers pause/resume.
  bool pause_resume_in_flight = false;  // a pause/resume is mid-transition.
  bool countdown_active = false;        // the pre-record countdown is running.
};

// One button's render decision.
struct BarButtonSpec {
  BarButtonId id = BarButtonId::kNone;
  bool present = false;  // false = not drawn for this state (e.g. Update hidden).
  BarButtonStyle style = BarButtonStyle::kNormal;
};

// Whether the phase permits showing the bar at all — the macOS
// `shouldShowPreRecordingBar` phase gate: idle(0), recording(2),
// pausedRecording(3). The controller ANDs this with its own engine-side flags
// (enabled / dismissed-for-cycle / area-selection-in-progress).
bool BarPhaseAllowsBar(int phase);

// Full visibility decision derivable from the pure inputs: phase-allowed AND
// NOT (idle with an active countdown) — the countdown owns the screen during
// the idle pre-roll, matching macOS. Engine-side flags are layered on top by
// the controller.
bool ShouldShowBar(const PreRecordingBarInputs& in);

// The record button glyph for a workflow phase.
RecordGlyph RecordGlyphFor(int phase);

// Compute every button's `present` + `style` for the given inputs, in stack
// order (indexed by `kBarButtonOrder`).
std::array<BarButtonSpec, kBarButtonCount> ComputeBarButtons(
    const PreRecordingBarInputs& in);

// A laid-out button rectangle in window client coordinates. A `kNone` id means
// the slot is absent (the button is not present) and the rect is degenerate.
struct BarButtonRect {
  BarButtonId id = BarButtonId::kNone;
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;

  bool Contains(int x, int y) const {
    return id != BarButtonId::kNone && x >= left && x < right && y >= top &&
           y < bottom;
  }
};

// Fixed bar height in logical (96-dpi) pixels; the controller scales it by DPI.
inline constexpr int kBarBaseHeight = 56;

// The content width the present buttons need at the given bar `height` — the
// window sizes to this so the bar grows/shrinks as Update / pause-resume toggle
// in and out, mirroring macOS `fittingSize`. All slot widths + gaps are
// expressed relative to `height`, so passing the DPI-scaled height yields a
// DPI-scaled width (same proportional trick as the recording indicator). Absent
// buttons contribute nothing.
int BarContentWidth(const std::array<BarButtonSpec, kBarButtonCount>& specs,
                    int height);

// The laid-out rectangles for every slot, indexed the same as the spec array.
struct BarLayout {
  std::array<BarButtonRect, kBarButtonCount> buttons{};
};

// Lay out the present buttons left-to-right within the client rect, packed from
// the left inset with a wider group gap where macOS draws separators (after
// close, and before the camera group). Absent buttons get a degenerate
// (`kNone`) rect at the same index.
BarLayout ComputeBarLayout(
    int client_width, int client_height,
    const std::array<BarButtonSpec, kBarButtonCount>& specs);

// Which present button (if any) contains the client-coordinate point. Returns
// `kNone` on a miss.
BarButtonId HitTestBarButton(const BarLayout& layout, int x, int y);

// Slice 5: the reverse-action id a button tap emits, as the `type` string in
// the `preRecordingBarAction` call. Derives pause vs resume from the phase
// (paused -> resumeTapped, else pauseTapped), matching macOS. Returns the empty
// string for `kNone`. Values mirror Dart `NativeBarAction`
// (lib/core/bridges/native_bar_action.dart) exactly.
const char* BarActionFor(BarButtonId id, int phase);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_PRERECORDINGBAR_PRE_RECORDING_BAR_MODEL_H_
