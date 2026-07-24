#include "Capture/PreRecordingBar/pre_recording_bar_model.h"

#include <algorithm>

namespace clingfy::capture {

namespace {

// WorkflowPhase wire values (mirror the Dart `WorkflowPhase` enum in
// app_models.dart). Only the ones the bar reasons about are named.
constexpr int kPhaseIdle = 0;
constexpr int kPhaseStarting = 1;
constexpr int kPhaseRecording = 2;
constexpr int kPhasePaused = 3;
constexpr int kPhaseStopping = 4;
constexpr int kPhaseFinalizing = 5;
constexpr int kPhaseExporting = 10;

// DisplayTargetMode indices (mirror the Dart `DisplayTargetMode` enum). Only the
// three the bar can accent are named.
constexpr int kModeDisplay = 0;  // explicitId
constexpr int kModeWindow = 2;   // singleAppWindow
constexpr int kModeArea = 3;     // areaRecording

// The source pickers + toggles are interactive only when the app is idle or
// sitting in a preview phase — parity with macOS `canInteract`, which disables
// them across starting/recording/paused/stopping/finalizing/exporting.
bool CanInteract(int phase) {
  switch (phase) {
    case kPhaseStarting:
    case kPhaseRecording:
    case kPhasePaused:
    case kPhaseStopping:
    case kPhaseFinalizing:
    case kPhaseExporting:
      return false;
    default:
      return true;
  }
}

// Style for a picker/toggle button: disabled wins over selected (a dimmed
// recording-time button never shows its accent), else selected when `on`.
BarButtonStyle PickerStyle(int phase, bool on) {
  if (!CanInteract(phase)) {
    return BarButtonStyle::kDisabled;
  }
  return on ? BarButtonStyle::kSelected : BarButtonStyle::kNormal;
}

// Slot width for a button, expressed relative to the bar height `h` so the whole
// layout scales with DPI (the controller passes the DPI-scaled height). Ratios
// chosen to fit an icon (square buttons) or icon + short label.
int SlotWidth(BarButtonId id, int h) {
  switch (id) {
    case BarButtonId::kClose:
      return h * 13 / 20;  // ~0.65h — compact icon-only.
    case BarButtonId::kRecord:
      return h * 4 / 5;  // ~0.80h — the record/stop disc.
    case BarButtonId::kPauseResume:
    case BarButtonId::kUpdate:
      return h * 3 / 2;  // ~1.50h — icon + PAUSE/RESUME/UPDATE label.
    default:
      return h * 6 / 5;  // ~1.20h — icon + Display/Window/Area/... label.
  }
}

int HPad(int h) { return std::max(1, h * 11 / 50); }        // ~0.22h
int VPad(int h) { return std::max(1, h * 7 / 50); }         // ~0.14h
int Gap(int h) { return std::max(1, h * 11 / 100); }        // ~0.11h
int GroupGap(int h) { return std::max(1, h * 8 / 25); }     // ~0.32h — separator.

// A group gap (macOS separator) precedes the Display group (after Close) and the
// Camera group (after Area); every other adjacent pair gets the normal gap.
bool StartsGroup(BarButtonId id) {
  return id == BarButtonId::kDisplay || id == BarButtonId::kCamera;
}

}  // namespace

bool BarPhaseAllowsBar(int phase) {
  return phase == kPhaseIdle || phase == kPhaseRecording ||
         phase == kPhasePaused;
}

bool ShouldShowBar(const PreRecordingBarInputs& in) {
  if (!BarPhaseAllowsBar(in.phase)) {
    return false;
  }
  // The idle countdown owns the screen during the pre-roll — hide the bar until
  // it finishes (macOS `shouldShowPreRecordingBar`).
  if (in.phase == kPhaseIdle && in.countdown_active) {
    return false;
  }
  return true;
}

RecordGlyph RecordGlyphFor(int phase) {
  switch (phase) {
    case kPhaseRecording:
    case kPhasePaused:
      return RecordGlyph::kStop;
    case kPhaseStarting:
    case kPhaseStopping:
    case kPhaseFinalizing:
      return RecordGlyph::kBusy;
    default:
      return RecordGlyph::kRecord;
  }
}

std::array<BarButtonSpec, kBarButtonCount> ComputeBarButtons(
    const PreRecordingBarInputs& in) {
  std::array<BarButtonSpec, kBarButtonCount> out{};
  for (int i = 0; i < kBarButtonCount; ++i) {
    const BarButtonId id = kBarButtonOrder[i];
    BarButtonSpec spec{id, true, BarButtonStyle::kNormal};
    switch (id) {
      case BarButtonId::kClose:
        // Dismissable any time except mid start/stop (macOS `closeButton`).
        spec.style = (in.phase == kPhaseStarting || in.phase == kPhaseStopping)
                         ? BarButtonStyle::kDisabled
                         : BarButtonStyle::kNormal;
        break;
      case BarButtonId::kDisplay:
        spec.style = PickerStyle(in.phase, in.target_mode == kModeDisplay);
        break;
      case BarButtonId::kWindow:
        spec.style = PickerStyle(in.phase, in.target_mode == kModeWindow);
        break;
      case BarButtonId::kArea:
        spec.style = PickerStyle(in.phase, in.target_mode == kModeArea);
        break;
      case BarButtonId::kCamera:
        spec.style = PickerStyle(in.phase, in.camera_selected);
        break;
      case BarButtonId::kMic:
        spec.style = PickerStyle(in.phase, in.mic_enabled);
        break;
      case BarButtonId::kSystemAudio:
        spec.style = PickerStyle(in.phase, in.system_audio_enabled);
        break;
      case BarButtonId::kPauseResume:
        // Only offered by a pause/resume-capable backend, and only while a
        // recording is live (recording or paused). Dimmed while a transition is
        // in flight (macOS `pauseResumeButton`).
        spec.present =
            in.can_pause_resume &&
            (in.phase == kPhaseRecording || in.phase == kPhasePaused);
        spec.style = in.pause_resume_in_flight ? BarButtonStyle::kDisabled
                                               : BarButtonStyle::kNormal;
        break;
      case BarButtonId::kRecord:
        // Always present for a shown bar; its record/stop/busy appearance is
        // carried by `RecordGlyphFor`, not the style (the red stop disc is not
        // "disabled"), so leave the style normal.
        spec.style = BarButtonStyle::kNormal;
        break;
      case BarButtonId::kUpdate:
        // Only when an update is actually available (macOS bounce button).
        spec.present = in.update_available;
        break;
      case BarButtonId::kNone:
        break;
    }
    out[i] = spec;
  }
  return out;
}

int BarContentWidth(const std::array<BarButtonSpec, kBarButtonCount>& specs,
                    int height) {
  const int h = std::max(1, height);
  int x = HPad(h);
  bool first = true;
  for (const BarButtonSpec& spec : specs) {
    if (!spec.present) {
      continue;
    }
    if (!first) {
      x += StartsGroup(spec.id) ? GroupGap(h) : Gap(h);
    }
    x += SlotWidth(spec.id, h);
    first = false;
  }
  return x + HPad(h);
}

BarLayout ComputeBarLayout(
    int client_width, int client_height,
    const std::array<BarButtonSpec, kBarButtonCount>& specs) {
  BarLayout out{};
  const int h = std::max(1, client_height);
  if (client_width <= 0 || client_height <= 0) {
    return out;
  }
  const int top = VPad(h);
  const int bottom = std::max(top + 1, h - VPad(h));

  int x = HPad(h);
  bool first = true;
  for (int i = 0; i < kBarButtonCount; ++i) {
    const BarButtonSpec& spec = specs[i];
    if (!spec.present) {
      continue;  // leave a degenerate kNone rect at this index.
    }
    if (!first) {
      x += StartsGroup(spec.id) ? GroupGap(h) : Gap(h);
    }
    const int w = SlotWidth(spec.id, h);
    out.buttons[i] = BarButtonRect{spec.id, x, top, x + w, bottom};
    x += w;
    first = false;
  }
  return out;
}

BarButtonId HitTestBarButton(const BarLayout& layout, int x, int y) {
  for (const BarButtonRect& rect : layout.buttons) {
    if (rect.Contains(x, y)) {
      return rect.id;
    }
  }
  return BarButtonId::kNone;
}

}  // namespace clingfy::capture
