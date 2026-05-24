#include "Bridge/method_dispatcher.h"

#include "Bridge/native_channel_names.h"

namespace clingfy::bridge {

MethodDispatcher::MethodDispatcher(flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, channel::kScreenRecorder,
          &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        router_.Dispatch(call, std::move(result));
      });
}

MethodDispatcher::~MethodDispatcher() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

}  // namespace clingfy::bridge
