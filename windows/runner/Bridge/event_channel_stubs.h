#ifndef RUNNER_BRIDGE_EVENT_CHANNEL_STUBS_H_
#define RUNNER_BRIDGE_EVENT_CHANNEL_STUBS_H_

#include <flutter/binary_messenger.h>
#include <flutter/event_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

namespace clingfy::bridge {

// Phase 0 placeholder for the four event channels that Flutter subscribes to
// at startup: screen_recorder/events, player/events, workflow/events,
// updater/events.
//
// Each channel is registered with a no-op stream handler so that
// `EventChannel.receiveBroadcastStream()` succeeds without throwing a
// MissingPluginException. No events are emitted yet — real producers wire in
// during later phases (device events in Phase 2, player events in Phase 5,
// workflow events alongside the recording lifecycle in Phase 4, updater
// events in Phase 10).
class EventChannelStubs {
 public:
  explicit EventChannelStubs(flutter::BinaryMessenger* messenger);
  ~EventChannelStubs();

  EventChannelStubs(const EventChannelStubs&) = delete;
  EventChannelStubs& operator=(const EventChannelStubs&) = delete;

 private:
  void Register(flutter::BinaryMessenger* messenger, const char* name);

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
