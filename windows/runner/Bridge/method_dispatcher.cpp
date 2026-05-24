#include "Bridge/method_dispatcher.h"

#include <sstream>
#include <string>

#include "Bridge/native_channel_names.h"
#include "Bridge/native_error_codes.h"

namespace clingfy::bridge {

MethodDispatcher::MethodDispatcher(flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, channel::kScreenRecorder,
          &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleCall(call, std::move(result));
      });
}

MethodDispatcher::~MethodDispatcher() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void MethodDispatcher::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Phase 0: catch-all stub.
  //
  // Real method routing lands in Phase 1. For now we surface a structured
  // error so the Flutter side can map it to a localized "not available on
  // Windows yet" message instead of crashing or showing a raw plugin error.
  std::ostringstream message;
  message << "Method '" << call.method_name()
          << "' is not implemented on Windows yet.";
  result->Error(error::kWindowsNotImplemented, message.str());
}

}  // namespace clingfy::bridge
