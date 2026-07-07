#include "Bridge/camera_overlay_move_publisher.h"

#include <memory>

#include "Bridge/native_channel_names.h"
#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

CameraOverlayMovePublisher& CameraOverlayMovePublisher::Instance() {
  static CameraOverlayMovePublisher instance;
  return instance;
}

void CameraOverlayMovePublisher::SetChannel(
    flutter::MethodChannel<flutter::EncodableValue>* channel) {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = channel;
}

void CameraOverlayMovePublisher::ClearChannel() {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = nullptr;
}

void CameraOverlayMovePublisher::EmitMoved(double normalized_x,
                                           double normalized_y) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr) {
      return;  // no listener / torn down
    }
  }
  // Marshal the reverse method-channel call to the platform thread (Flutter
  // requires it there). Re-check the channel inside the posted task so a
  // teardown mid-flight doesn't call into a dead channel.
  PlatformThreadDispatcher::Instance().Post([this, normalized_x,
                                             normalized_y] {
    flutter::MethodChannel<flutter::EncodableValue>* channel_snapshot = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      channel_snapshot = channel_;
    }
    if (channel_snapshot == nullptr) {
      return;
    }
    // Map payload — Dart reads args['normalizedX'] / args['normalizedY'].
    channel_snapshot->InvokeMethod(
        method::kCameraOverlayMoved,
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("normalizedX"),
             flutter::EncodableValue(normalized_x)},
            {flutter::EncodableValue("normalizedY"),
             flutter::EncodableValue(normalized_y)},
        }));
  });
}

}  // namespace clingfy::bridge
