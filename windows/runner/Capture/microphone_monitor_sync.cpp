#include "Capture/microphone_monitor_sync.h"

#include <cstdio>

#include "Audio/microphone_level_monitor.h"
#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Capture/windows_selection_state.h"

namespace clingfy::capture {

void SyncMicrophoneLevelMonitor(bool recording) {
  auto reconcile = [recording] {
    // The selection is read in the task, not captured at post time, so a
    // device change that crossed a reconcile in flight still wins.
    const auto selected = WindowsSelectionState::Instance().MicrophoneId();
    // One line per reconcile (a device pick, a recording start, a recording
    // end) -- not per sample. Worth keeping: the state that decides whether
    // the meter runs lives in two places, and when it comes out wrong this
    // is the line that says which one was wrong.
    char buf[96];
    std::snprintf(buf, sizeof(buf),
                  "MicrophoneLevelMonitor: reconcile selected=%s recording=%d",
                  selected.has_value() ? (selected->empty() ? "<empty>" : "yes")
                                       : "none",
                  recording ? 1 : 0);
    clingfy::bridge::devices::LogDeviceProbe(buf);
    clingfy::audio::MicrophoneLevelMonitor::Instance().Apply(selected,
                                                             recording);
  };

  // Post() already runs the task inline when the dispatcher is not up, which
  // is the case in unit tests and before FlutterWindow finishes startup. No
  // real `setAudioSource` can arrive before then -- the dispatcher is
  // initialized ahead of channel registration -- so in practice the inline
  // path only happens under test, with no device selected.
  clingfy::bridge::PlatformThreadDispatcher::Instance().Post(
      std::move(reconcile));
}

}  // namespace clingfy::capture
