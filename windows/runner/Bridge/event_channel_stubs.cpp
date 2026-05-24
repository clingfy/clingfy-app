#include "Bridge/event_channel_stubs.h"

#include <flutter/event_stream_handler_functions.h>

#include "Bridge/native_channel_names.h"

namespace clingfy::bridge {

namespace {

// A stream handler that accepts the listen call, ignores the sink, and never
// emits anything. Real handlers will replace this in later phases.
class NoopStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  NoopStreamHandler() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* /*arguments*/,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& /*events*/)
      override {
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* /*arguments*/) override {
    return nullptr;
  }
};

}  // namespace

EventChannelStubs::EventChannelStubs(flutter::BinaryMessenger* messenger) {
  Register(messenger, channel::kScreenRecorderEvents);
  Register(messenger, channel::kPlayerEvents);
  Register(messenger, channel::kWorkflowEvents);
  Register(messenger, channel::kUpdaterEvents);
}

EventChannelStubs::~EventChannelStubs() {
  for (auto& channel : channels_) {
    if (channel) {
      channel->SetStreamHandler(nullptr);
    }
  }
}

void EventChannelStubs::Register(flutter::BinaryMessenger* messenger,
                                 const char* name) {
  auto channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, name, &flutter::StandardMethodCodec::GetInstance());
  channel->SetStreamHandler(std::make_unique<NoopStreamHandler>());
  channels_.push_back(std::move(channel));
}

}  // namespace clingfy::bridge
