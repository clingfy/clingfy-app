#include <cmath>

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
    // Labelled map payload. Must stay in step with macOS
    // Runner/Core/JobProgress.swift and lib/core/bridges/job_progress.dart.
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("job")] = flutter::EncodableValue("export");
    payload[flutter::EncodableValue("stage")] =
        flutter::EncodableValue("rendering");
    // Omitted rather than null when not finite, so Dart shows an indeterminate
    // spinner instead of a bar pinned at zero.
    if (std::isfinite(fraction)) {
      const double clamped = fraction < 0.0 ? 0.0 : (fraction > 1.0 ? 1.0 : fraction);
      payload[flutter::EncodableValue("fraction")] =
          flutter::EncodableValue(clamped);
    }
    channel_snapshot->InvokeMethod(
        method::kUpdateExportProgress,
        std::make_unique<flutter::EncodableValue>(payload));
  });
}

}  // namespace clingfy::bridge
