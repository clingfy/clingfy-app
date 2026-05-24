#ifndef RUNNER_CAPTURE_WINDOWS_SELECTION_STATE_H_
#define RUNNER_CAPTURE_WINDOWS_SELECTION_STATE_H_

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>

// Process-level selection cache for Windows recording.
//
// Phase 1/2 left the `setDisplay` / `setDisplayTargetMode` / `setAudioSource`
// / `setVideoSource` handlers as pure no-ops because nothing on the native
// side consumed the values. Phase 3B introduces the first real consumer —
// the recording engine — so the setters now record into this singleton and
// `RecordingEngine::Start` reads a snapshot of it.
//
// The state is intentionally small. It does NOT cache device snapshots,
// HMONITOR handles, or human-readable names; those are looked up fresh at
// Start time so a docked display or a hot-unplugged camera cannot pin a
// stale identifier into a recording.
//
// Target mode mirrors the Dart `DisplayTargetMode` enum (lib/core/models/
// app_models.dart). Indices match the Dart side exactly so the router can
// store the raw integer without translation.
namespace clingfy::capture {

enum class DisplayTargetMode : std::int32_t {
  kExplicitId = 0,
  kAppWindow = 1,
  kSingleAppWindow = 2,
  kAreaRecording = 3,
  kMouseAtStart = 4,
  kFollowMouse = 5,
};

class WindowsSelectionState {
 public:
  static WindowsSelectionState& Instance();

  WindowsSelectionState(const WindowsSelectionState&) = delete;
  WindowsSelectionState& operator=(const WindowsSelectionState&) = delete;

  // Selected display id from Phase 2's display enumerator (the hashed
  // device-interface path). `std::nullopt` means "the user has not picked a
  // display yet" — the engine treats that as "use the primary monitor" for
  // a friendlier first-run experience.
  void SetDisplayId(std::optional<std::int64_t> id);
  std::optional<std::int64_t> DisplayId() const;

  // Target mode. Defaults to `kExplicitId` so a Dart caller that omits the
  // setter still gets a sensible default (display recording).
  void SetTargetMode(DisplayTargetMode mode);
  DisplayTargetMode TargetMode() const;

  // Selected microphone endpoint id from `setAudioSource`. Phase 3D starts
  // consuming this; tracking it here in 3B lets the wiring land alongside
  // the rest of the engine plumbing rather than churning the router again.
  // System audio does not need a corresponding setter — the loopback path
  // always opens the default render endpoint, and the
  // `systemAudioEnabled` boolean on `startRecording` is the gate.
  void SetMicrophoneId(std::optional<std::string> id);
  std::optional<std::string> MicrophoneId() const;

  // Test seam — used by `windows_selection_state_test.cpp` to start each
  // case from a clean slate.
  void ResetForTesting();

 private:
  WindowsSelectionState() = default;

  mutable std::mutex mutex_;
  std::optional<std::int64_t> display_id_;
  DisplayTargetMode target_mode_ = DisplayTargetMode::kExplicitId;
  std::optional<std::string> microphone_id_;
};

// Convenience: clamp an arbitrary integer to a known `DisplayTargetMode`.
// Returns `kExplicitId` for out-of-range values rather than rejecting the
// call — Phase 3B will reject unsupported modes at engine.Start time with a
// structured error, so the setter staying tolerant prevents the UI from
// getting stuck if Dart sends a future mode the native side doesn't know
// about.
DisplayTargetMode TargetModeFromInt(std::int32_t raw);
const char* TargetModeName(DisplayTargetMode mode);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_WINDOWS_SELECTION_STATE_H_
