#ifndef RUNNER_BRIDGE_PRE_RECORDING_BAR_ACTION_PUBLISHER_H_
#define RUNNER_BRIDGE_PRE_RECORDING_BAR_ACTION_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <mutex>

// Slice 5 (Windows pre-recording bar): reverse-bridge publisher for the bar's
// button taps. When the user clicks a bar button, the overlay thread fires the
// reverse method-channel call
// `channel.invokeMethod("preRecordingBarAction", {type: <action>, payload: nil})`.
// Dart's NativeBridge reads `type` + `payload` and dispatches to
// home_actions.handleNativeBarAction, which owns the source/record/pause logic —
// macOS parity (the bar reports the tap UP to Dart). The action-type strings
// come from the pure model `BarActionFor`.
//
// Same lifecycle + threading contract as IndicatorEventPublisher /
// CameraOverlayMovePublisher: `flutter_window` hands this singleton the
// screen_recorder method channel at startup and clears it at teardown; the
// InvokeMethod is marshaled to the platform thread via
// PlatformThreadDispatcher::Post; emits are dropped silently when no channel is
// attached (tests / teardown).
namespace clingfy::bridge {

class PreRecordingBarActionPublisher {
 public:
  static PreRecordingBarActionPublisher& Instance();

  PreRecordingBarActionPublisher(const PreRecordingBarActionPublisher&) =
      delete;
  PreRecordingBarActionPublisher& operator=(
      const PreRecordingBarActionPublisher&) = delete;

  // Borrow the screen_recorder method channel (owned by MethodDispatcher).
  void SetChannel(flutter::MethodChannel<flutter::EncodableValue>* channel);
  void ClearChannel();

  // Fire `preRecordingBarAction` with {type: `action_type`, payload: null}.
  // `action_type` is a `BarActionFor` string (a stable literal / static
  // storage). Safe from any thread; a no-op when the type is empty or no
  // channel is attached.
  void EmitAction(const char* action_type);

 private:
  PreRecordingBarActionPublisher() = default;

  mutable std::mutex mutex_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_PRE_RECORDING_BAR_ACTION_PUBLISHER_H_
