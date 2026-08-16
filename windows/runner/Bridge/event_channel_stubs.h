#ifndef RUNNER_BRIDGE_EVENT_CHANNEL_STUBS_H_
#define RUNNER_BRIDGE_EVENT_CHANNEL_STUBS_H_

#include <flutter/binary_messenger.h>
#include <flutter/event_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

namespace clingfy::bridge {

// Registers the four event channels Flutter subscribes to at startup:
// screen_recorder/events, player/events, workflow/events, updater/events.
//
// The name is now historical. This began as a Phase-0 placeholder that
// registered no-op handlers so `EventChannel.receiveBroadcastStream()` would
// not throw MissingPluginException; every channel has since graduated to a
// real publisher — workflow in Phase 3E, player in Step 5.4, updater in Phase
// 10.6, and screen_recorder/events (device hot-plug) last of all. No stub
// remains, and `Register()` — the helper that installed the no-op handler — is
// gone with the last of them.
class EventChannelStubs {
 public:
  explicit EventChannelStubs(flutter::BinaryMessenger* messenger);
  ~EventChannelStubs();

  EventChannelStubs(const EventChannelStubs&) = delete;
  EventChannelStubs& operator=(const EventChannelStubs&) = delete;

 private:
  // screen_recorder/events: forwards sinks into `DeviceEventPublisher` and
  // starts / stops the OS-level `DeviceChangeWatcher` on listen / cancel, so
  // hot-plugged microphones, cameras and displays reach Dart's
  // DeviceController instead of leaving its lists stale.
  void RegisterDevices(flutter::BinaryMessenger* messenger);

  // Phase 3E: workflow/events is no longer a stub. This registers a real
  // stream handler that forwards listen / cancel into the process-level
  // `WorkflowEventPublisher` so the recording engine can push events
  // back to Flutter.
  void RegisterWorkflow(flutter::BinaryMessenger* messenger);

  // Step 5.4: player/events is no longer a stub. Same shape as
  // RegisterWorkflow, forwarding sinks into `PlayerEventPublisher`
  // so `PreviewEngine` can push playerTick / playerState / playerError
  // / playerWarning events back to Dart's PlayerController.
  void RegisterPlayer(flutter::BinaryMessenger* messenger);

  // Phase 10.6: updater/events is no longer a stub. Forwards sinks into
  // `UpdaterEventPublisher` so the update checker's worker thread can push
  // checking / updateAvailable / noUpdateAvailable / updateError back to
  // Dart's NativeBridge.
  void RegisterUpdater(flutter::BinaryMessenger* messenger);

  std::vector<std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>>
      channels_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_EVENT_CHANNEL_STUBS_H_
