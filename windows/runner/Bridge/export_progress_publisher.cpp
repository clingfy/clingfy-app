#include "Bridge/export_progress_publisher.h"

#include <memory>

#include "Bridge/native_channel_names.h"
#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

ExportProgressPublisher& ExportProgressPublisher::Instance() {
  static ExportProgressPublisher instance;
  return instance;
}

void ExportProgressPublisher::SetChannel(
    flutter::MethodChannel<flutter::EncodableValue>* channel) {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = channel;
}

void ExportProgressPublisher::ClearChannel() {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = nullptr;
}

void ExportProgressPublisher::EmitProgress(double fraction) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr) {
      return;  // no listener / torn down
    }
  }
  // Marshal the reverse method-channel call to the platform thread (Flutter
  // requires it there). Re-check the channel inside the posted task so a
  // teardown mid-flight doesn't call into a dead channel.
  PlatformThreadDispatcher::Instance().Post([this, fraction] {
    flutter::MethodChannel<flutter::EncodableValue>* channel_snapshot = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      channel_snapshot = channel_;
    }
    if (channel_snapshot == nullptr) {
      return;
    }
    // BARE double payload — Dart reads `call.arguments as double?`.
    channel_snapshot->InvokeMethod(
        method::kUpdateExportProgress,
        std::make_unique<flutter::EncodableValue>(fraction));
  });
}

}  // namespace clingfy::bridge
