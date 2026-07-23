#ifndef RUNNER_BRIDGE_INDICATOR_EVENT_PUBLISHER_H_
#define RUNNER_BRIDGE_INDICATOR_EVENT_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <mutex>

// Slice 2 (Windows recording indicator): reverse-bridge publisher for the
// pill's control taps. When the user clicks pause / stop / resume on the
// on-screen recording indicator, the overlay thread fires the matching
// no-argument reverse method-channel call
// (`channel.invokeMethod("indicatorPauseTapped")` etc). Dart's NativeBridge
// dispatches it to home_bindings, which drives pauseRecording /
// onToggleRecording / resumeRecording — macOS parity (the indicator reports the
// tap UP to Dart; Dart owns the recorder state machine).
//
// Same lifecycle + threading contract as CameraOverlayMovePublisher:
// `flutter_window` hands this singleton the screen_recorder method channel at
// startup and clears it at teardown; the InvokeMethod is marshaled to the
// platform thread via PlatformThreadDispatcher::Post; emits are dropped
// silently when no channel is attached (tests / teardown).
namespace clingfy::bridge {

class IndicatorEventPublisher {
 public:
  static IndicatorEventPublisher& Instance();

  IndicatorEventPublisher(const IndicatorEventPublisher&) = delete;
  IndicatorEventPublisher& operator=(const IndicatorEventPublisher&) = delete;

  // Borrow the screen_recorder method channel (owned by MethodDispatcher).
  void SetChannel(flutter::MethodChannel<flutter::EncodableValue>* channel);
  void ClearChannel();

  // Fire the matching reverse call (no arguments). Safe from any thread; a
  // no-op when no channel is attached.
  void EmitPauseTapped();
  void EmitStopTapped();
  void EmitResumeTapped();

 private:
  IndicatorEventPublisher() = default;

  // Marshal `method_name` (a `clingfy::bridge::method::*` constant) onto the
  // platform thread and invoke it with null arguments, re-checking the channel
  // inside the posted task so a teardown mid-flight can't call a dead channel.
  void Emit(const char* method_name);

  mutable std::mutex mutex_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_INDICATOR_EVENT_PUBLISHER_H_
