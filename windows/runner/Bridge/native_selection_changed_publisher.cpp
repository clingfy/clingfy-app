#include "Bridge/native_selection_changed_publisher.h"

#include <cstdint>
#include <memory>
#include <utility>

#include "Bridge/native_channel_names.h"
#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

NativeSelectionChangedPublisher&
NativeSelectionChangedPublisher::Instance() {
  static NativeSelectionChangedPublisher instance;
  return instance;
}

void NativeSelectionChangedPublisher::SetChannel(
    flutter::MethodChannel<flutter::EncodableValue>* channel) {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = channel;
}

void NativeSelectionChangedPublisher::ClearChannel() {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = nullptr;
}

void NativeSelectionChangedPublisher::EmitStringSelection(
    const char* type, const std::string& id) {
  if (type == nullptr) {
    return;
  }
  Emit(type, flutter::EncodableValue(id));
}

void NativeSelectionChangedPublisher::EmitIntSelection(const char* type,
                                                       std::int64_t id) {
  if (type == nullptr) {
    return;
  }
  Emit(type, flutter::EncodableValue(id));
}

void NativeSelectionChangedPublisher::EmitNoneSelection(const char* type) {
  if (type == nullptr) {
    return;
  }
  Emit(type, flutter::EncodableValue());  // monostate -> null id (deselect).
}

void NativeSelectionChangedPublisher::Emit(std::string type,
                                           flutter::EncodableValue id) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr) {
      return;  // no listener / torn down.
    }
  }
  // Flutter requires reverse method-channel calls on the platform thread; the
  // pick originates on the overlay thread. Re-check the channel inside the
  // posted task so a teardown mid-flight doesn't call into a dead channel.
  PlatformThreadDispatcher::Instance().Post(
      [this, type = std::move(type), id = std::move(id)]() mutable {
        flutter::MethodChannel<flutter::EncodableValue>* channel_snapshot =
            nullptr;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          channel_snapshot = channel_;
        }
        if (channel_snapshot == nullptr) {
          return;
        }
        flutter::EncodableMap args{
            {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
            {flutter::EncodableValue("id"), std::move(id)},
        };
        channel_snapshot->InvokeMethod(
            method::kNativeSelectionChanged,
            std::make_unique<flutter::EncodableValue>(std::move(args)));
      });
}

}  // namespace clingfy::bridge
