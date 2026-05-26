#include "Bridge/event_channel_stubs.h"

#include <flutter/event_stream_handler_functions.h>

#include "Bridge/native_channel_names.h"
#include "Bridge/player_event_publisher.h"
#include "Bridge/workflow_event_publisher.h"

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

// Phase 3E forwards listen / cancel for the workflow channel to the
// process-level `WorkflowEventPublisher`. The recording engine emits
// events through the publisher; the publisher writes to whichever sink
// is currently installed.
class WorkflowStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  WorkflowStreamHandler() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* /*arguments*/,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    WorkflowEventPublisher::Instance().SetSink(std::move(events));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* /*arguments*/) override {
    WorkflowEventPublisher::Instance().ClearSink();
    return nullptr;
  }
};

// Step 5.4 wires player/events into the same shape as the workflow
// publisher. PreviewEngine pushes playerTick / playerState /
// playerError / playerWarning through PlayerEventPublisher; the sink
// installed here is what Dart's PlayerController subscribes to.
class PlayerStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  PlayerStreamHandler() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* /*arguments*/,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    PlayerEventPublisher::Instance().SetSink(std::move(events));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* /*arguments*/) override {
    PlayerEventPublisher::Instance().ClearSink();
    return nullptr;
  }
};

}  // namespace

EventChannelStubs::EventChannelStubs(flutter::BinaryMessenger* messenger) {
  Register(messenger, channel::kScreenRecorderEvents);
  RegisterPlayer(messenger);
  RegisterWorkflow(messenger);
  Register(messenger, channel::kUpdaterEvents);
}

EventChannelStubs::~EventChannelStubs() {
  for (auto& channel : channels_) {
    if (channel) {
      channel->SetStreamHandler(nullptr);
    }
  }
  // Make sure any sinks still held by the publishers (e.g. Dart never
  // sent a cancel before app teardown) are released before the engine
  // tries to use them on the next launch.
  PlayerEventPublisher::Instance().ClearSink();
  WorkflowEventPublisher::Instance().ClearSink();
}

void EventChannelStubs::Register(flutter::BinaryMessenger* messenger,
                                 const char* name) {
  auto channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, name, &flutter::StandardMethodCodec::GetInstance());
  channel->SetStreamHandler(std::make_unique<NoopStreamHandler>());
  channels_.push_back(std::move(channel));
}

void EventChannelStubs::RegisterWorkflow(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, channel::kWorkflowEvents,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetStreamHandler(std::make_unique<WorkflowStreamHandler>());
  channels_.push_back(std::move(channel));
}

void EventChannelStubs::RegisterPlayer(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, channel::kPlayerEvents,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetStreamHandler(std::make_unique<PlayerStreamHandler>());
  channels_.push_back(std::move(channel));
}

}  // namespace clingfy::bridge
