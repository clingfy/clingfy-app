#include "Bridge/indicator_event_publisher.h"

#include <memory>

#include "Bridge/native_channel_names.h"
#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

IndicatorEventPublisher& IndicatorEventPublisher::Instance() {
  static IndicatorEventPublisher instance;
  return instance;
}

void IndicatorEventPublisher::SetChannel(
    flutter::MethodChannel<flutter::EncodableValue>* channel) {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = channel;
}

void IndicatorEventPublisher::ClearChannel() {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = nullptr;
}

void IndicatorEventPublisher::EmitPauseTapped() {
  Emit(method::kIndicatorPauseTapped);
}

void IndicatorEventPublisher::EmitStopTapped() {
  Emit(method::kIndicatorStopTapped);
}

void IndicatorEventPublisher::EmitResumeTapped() {
  Emit(method::kIndicatorResumeTapped);
}

void IndicatorEventPublisher::Emit(const char* method_name) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr) {
      return;  // no listener / torn down
    }
  }
  // Flutter requires reverse method-channel calls on the platform thread; the
  // tap originates on the overlay thread. Re-check the channel inside the
  // posted task so a teardown mid-flight doesn't call into a dead channel.
  PlatformThreadDispatcher::Instance().Post([this, method_name] {
    flutter::MethodChannel<flutter::EncodableValue>* channel_snapshot = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      channel_snapshot = channel_;
    }
    if (channel_snapshot == nullptr) {
      return;
    }
    channel_snapshot->InvokeMethod(method_name, nullptr);
  });
}

}  // namespace clingfy::bridge
