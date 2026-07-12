#ifndef RUNNER_SERVICES_KEEP_AWAKE_H_
#define RUNNER_SERVICES_KEEP_AWAKE_H_

#include <windows.h>

namespace clingfy::services {

// RAII power request that keeps the machine out of Modern Standby (and
// optionally keeps the display on) while long-running work is in flight.
//
// Why this exists: a ~55-minute recording session proved that nothing stopped
// Windows from entering Modern Standby while the app had work pending — sleep
// invalidates the GPU/media stack (WinRT frame server, D3D devices), which
// killed the inline preview (frame_copy device loss) and a subsequent export
// (CreateTexture2D failure). macOS holds a `.userInitiated` activity during
// recording; this is the Windows counterpart.
//
// Built on PowerCreateRequest/PowerSetRequest (handle-based, NOT the
// thread-affine SetThreadExecutionState), so construction and destruction may
// happen on different threads and the request shows up in `powercfg
// /requests` with the reason string for support diagnostics.
//
// Best-effort: failure to acquire the request is logged by the caller via
// active() — never a reason to block recording or export.
class KeepAwake {
 public:
  enum class Mode {
    // Prevent system sleep only (exports: the display may turn off, the
    // machine must keep working).
    kSystem,
    // Prevent system sleep AND display turn-off (recording: the captured
    // display must stay on — a dark display records black frames, and on
    // Modern Standby machines display-off cascades into system sleep).
    kSystemAndDisplay,
  };

  // `reason` appears verbatim in `powercfg /requests`.
  KeepAwake(Mode mode, const wchar_t* reason);
  ~KeepAwake();

  KeepAwake(const KeepAwake&) = delete;
  KeepAwake& operator=(const KeepAwake&) = delete;

  // True when the system-required request is actually held.
  bool active() const { return system_set_; }

 private:
  HANDLE request_ = nullptr;
  bool system_set_ = false;
  bool display_set_ = false;
};

}  // namespace clingfy::services

#endif  // RUNNER_SERVICES_KEEP_AWAKE_H_
