#include "Bridge/event_channel_stubs.h"

#include <flutter/event_stream_handler_functions.h>

#include "Bridge/Devices/device_change_watcher.h"
#include "Bridge/device_event_publisher.h"
#include "Bridge/native_channel_names.h"
#include "Bridge/player_event_publisher.h"
#include "Bridge/project_open_coordinator.h"
#include "Bridge/updater_event_publisher.h"
#include "Bridge/workflow_event_publisher.h"

namespace clingfy::bridge {

namespace {

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
    // Step 5.6: drain pending `openProjectRequest` events now that Dart
    // has a listener. Cold-start argv paths enqueue before this point;
    // without the flush they would never reach Dart.
    ProjectOpenCoordinator::Instance().OnSinkAttached();
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* /*arguments*/) override {
    WorkflowEventPublisher::Instance().ClearSink();
    ProjectOpenCoordinator::Instance().OnSinkDetached();
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

// Phase 10.6 wires updater/events onto UpdaterEventPublisher (was a
// NoopStreamHandler). The update checker's worker thread emits checking /
// updateAvailable / noUpdateAvailable / updateError through the publisher.
class UpdaterStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  UpdaterStreamHandler() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* /*arguments*/,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    UpdaterEventPublisher::Instance().SetSink(std::move(events));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* /*arguments*/) override {
    UpdaterEventPublisher::Instance().ClearSink();
    return nullptr;
  }
};

// Device hot-plug. The last channel still on the Phase-0 stub path: Dart's
// DeviceController has always subscribed here and never heard anything, so a
// mic plugged in mid-session left every list stale.
//
// The OS listeners start on FIRST LISTEN rather than at construction. There is
// no point holding a WASAPI notification registration and a message-only
// window open when nobody is subscribed, and starting here means the watcher's
// lifetime is exactly the lifetime of a live sink.
class DeviceStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  DeviceStreamHandler() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* /*arguments*/,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    DeviceEventPublisher::Instance().SetSink(std::move(events));
    devices::DeviceChangeWatcher::Instance().Start();
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* /*arguments*/) override {
    devices::DeviceChangeWatcher::Instance().Stop();
    DeviceEventPublisher::Instance().ClearSink();
    return nullptr;
  }
};

}  // namespace

EventChannelStubs::EventChannelStubs(flutter::BinaryMessenger* messenger) {
  RegisterDevices(messenger);
  RegisterPlayer(messenger);
  RegisterWorkflow(messenger);
  RegisterUpdater(messenger);
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
  UpdaterEventPublisher::Instance().ClearSink();
  // Stop the OS listeners BEFORE dropping the sink: a WASAPI callback racing
  // teardown would otherwise schedule an emit against a dying engine.
  devices::DeviceChangeWatcher::Instance().Stop();
  DeviceEventPublisher::Instance().ClearSink();
  DeviceEventPublisher::Instance().ClearObservers();
}

void EventChannelStubs::RegisterDevices(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, channel::kScreenRecorderEvents,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetStreamHandler(std::make_unique<DeviceStreamHandler>());
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

void EventChannelStubs::RegisterUpdater(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, channel::kUpdaterEvents,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetStreamHandler(std::make_unique<UpdaterStreamHandler>());
  channels_.push_back(std::move(channel));
}

}  // namespace clingfy::bridge
