#ifndef RUNNER_BRIDGE_NATIVE_SELECTION_CHANGED_PUBLISHER_H_
#define RUNNER_BRIDGE_NATIVE_SELECTION_CHANGED_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <mutex>
#include <string>

// Slice 6 (Windows pre-recording bar pickers): reverse-bridge publisher for a
// native device pick. When the user chooses a display / window / mic / camera
// from a native dropdown popover, the overlay thread fires
// `channel.invokeMethod("nativeSelectionChanged", {type, id})`. Dart's
// NativeBridge routes it to home_actions.handleNativeSelectionChanged, which
// drives deviceController.setDisplay / setAppWindow / setAudioSource /
// setCamSource — id null means "deselect / none" (macOS parity:
// PreRecordingBarController.notifyFlutterSelection). Keeping Dart as the source
// of truth: the popover reports the pick UP, Dart applies it and re-pushes the
// bar state (Windows has no direct engine device-selection API — selection is
// stored in WindowsSelectionState only via the router from Dart).
//
// Same lifecycle + threading contract as PreRecordingBarActionPublisher /
// IndicatorEventPublisher: `flutter_window` hands this singleton the
// screen_recorder method channel at startup and clears it at teardown; the
// InvokeMethod is marshaled to the platform thread via
// PlatformThreadDispatcher::Post; emits are dropped when no channel is attached.
namespace clingfy::bridge {

class NativeSelectionChangedPublisher {
 public:
  static NativeSelectionChangedPublisher& Instance();

  NativeSelectionChangedPublisher(const NativeSelectionChangedPublisher&) =
      delete;
  NativeSelectionChangedPublisher& operator=(
      const NativeSelectionChangedPublisher&) = delete;

  // Borrow the screen_recorder method channel (owned by MethodDispatcher).
  void SetChannel(flutter::MethodChannel<flutter::EncodableValue>* channel);
  void ClearChannel();

  // Fire `nativeSelectionChanged` with {type, id: <string>}. `type` is a
  // NativeSelectionType string ("mic" / "camera" / ...). Safe from any thread;
  // a no-op when no channel is attached.
  void EmitStringSelection(const char* type, const std::string& id);

  // Fire `nativeSelectionChanged` with {type, id: <int64>} (display / window).
  void EmitIntSelection(const char* type, std::int64_t id);

  // Fire `nativeSelectionChanged` with {type, id: null} — the "none / deselect"
  // pick (e.g. "Do not record audio", "No camera").
  void EmitNoneSelection(const char* type);

 private:
  NativeSelectionChangedPublisher() = default;

  // Marshal an invoke onto the platform thread with args {type, id}. `id` is
  // moved into the posted task; the channel is re-checked inside it so a
  // teardown mid-flight can't call a dead channel.
  void Emit(std::string type, flutter::EncodableValue id);

  mutable std::mutex mutex_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_NATIVE_SELECTION_CHANGED_PUBLISHER_H_
