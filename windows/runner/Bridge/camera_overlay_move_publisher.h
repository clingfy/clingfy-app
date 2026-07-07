#ifndef RUNNER_BRIDGE_CAMERA_OVERLAY_MOVE_PUBLISHER_H_
#define RUNNER_BRIDGE_CAMERA_OVERLAY_MOVE_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <mutex>

// Process-level publisher for floating camera-bubble drag write-back.
//
// When the user drags the floating bubble, macOS reports the resulting
// normalized center back to Dart via a reverse METHOD-channel call:
// `channel.invokeMethod("cameraOverlayMoved", {normalizedX, normalizedY})`
// (ScreenRecorderEventBridge). Dart persists it as the custom position
// (NativeBridge -> OverlayController._onCameraOverlayMovedFromNative), so the
// bubble reopens where the user left it and later geometry-store revisions
// (e.g. a size change) do not teleport it back to a stale position. This is
// the Windows counterpart, fed by CameraFloatingOverlay on drag end
// (WM_EXITSIZEMOVE).
//
// Same lifecycle as ExportProgressPublisher: `flutter_window` hands this
// singleton the screen_recorder method channel at startup and clears it at
// teardown. EmitMoved is safe from the overlay thread — the InvokeMethod is
// marshaled to the platform thread via PlatformThreadDispatcher::Post, and
// emits are dropped silently when no channel is attached (tests / teardown).
namespace clingfy::bridge {

class CameraOverlayMovePublisher {
 public:
  static CameraOverlayMovePublisher& Instance();

  CameraOverlayMovePublisher(const CameraOverlayMovePublisher&) = delete;
  CameraOverlayMovePublisher& operator=(const CameraOverlayMovePublisher&) =
      delete;

  // Borrow the screen_recorder method channel (owned by MethodDispatcher).
  void SetChannel(flutter::MethodChannel<flutter::EncodableValue>* channel);
  void ClearChannel();

  // Report the bubble's new normalized (0..1 of the work area) center to Dart.
  // Safe from any thread; a no-op when no channel is attached.
  void EmitMoved(double normalized_x, double normalized_y);

 private:
  CameraOverlayMovePublisher() = default;

  mutable std::mutex mutex_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_CAMERA_OVERLAY_MOVE_PUBLISHER_H_
