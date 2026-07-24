#include "Bridge/pre_recording_bar_action_publisher.h"

#include <memory>
#include <string>

#include "Bridge/native_channel_names.h"
#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

PreRecordingBarActionPublisher& PreRecordingBarActionPublisher::Instance() {
  static PreRecordingBarActionPublisher instance;
  return instance;
}

void PreRecordingBarActionPublisher::SetChannel(
    flutter::MethodChannel<flutter::EncodableValue>* channel) {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = channel;
}

void PreRecordingBarActionPublisher::ClearChannel() {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = nullptr;
}

void PreRecordingBarActionPublisher::EmitAction(const char* action_type) {
  if (action_type == nullptr || action_type[0] == '\0') {
    return;  // no action (e.g. a background / disabled tap).
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr) {
      return;  // no listener / torn down.
    }
  }
  // Copy the type into the task so the payload owns its own storage (the source
  // is static, but copying keeps the contract obvious). Marshal to the platform
  // thread (Flutter requires reverse calls there); re-check the channel inside
  // the task so a teardown mid-flight can't call a dead channel.
  const std::string type(action_type);
  PlatformThreadDispatcher::Instance().Post([this, type] {
    flutter::MethodChannel<flutter::EncodableValue>* channel_snapshot = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      channel_snapshot = channel_;
    }
    if (channel_snapshot == nullptr) {
      return;
    }
    flutter::EncodableMap args{
        {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
        {flutter::EncodableValue("payload"), flutter::EncodableValue()},
    };
    channel_snapshot->InvokeMethod(
        method::kPreRecordingBarAction,
        std::make_unique<flutter::EncodableValue>(std::move(args)));
  });
}

}  // namespace clingfy::bridge
