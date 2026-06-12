#include "Bridge/updater_event_publisher.h"

#include <utility>

#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

namespace {

flutter::EncodableMap MakeEvent(const std::string& type) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
  };
}

}  // namespace

UpdaterEventPublisher& UpdaterEventPublisher::Instance() {
  static UpdaterEventPublisher instance;
  return instance;
}

void UpdaterEventPublisher::SetSink(std::unique_ptr<EventSink> sink) {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_ = std::move(sink);
}

void UpdaterEventPublisher::ClearSink() {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_.reset();
}

bool UpdaterEventPublisher::has_sink() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return sink_ != nullptr;
}

void UpdaterEventPublisher::EmitMap(flutter::EncodableMap event) {
  // Same double no-sink check as WorkflowEventPublisher: once eagerly, once
  // at dispatch time, so a subscription cancelled mid-flight never receives
  // a stale event. The update checker emits from its worker thread; the
  // dispatcher marshals delivery onto the platform thread (or runs inline
  // when uninitialized — tests, cold start).
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sink_ == nullptr) return;
  }
  PlatformThreadDispatcher::Instance().Post(
      [this, event = std::move(event)]() mutable {
        EventSink* sink_snapshot = nullptr;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          sink_snapshot = sink_.get();
        }
        if (sink_snapshot == nullptr) return;
        sink_snapshot->Success(flutter::EncodableValue(std::move(event)));
      });
}

void UpdaterEventPublisher::EmitChecking() {
  EmitMap(MakeEvent("checking"));
}

void UpdaterEventPublisher::EmitUpdateAvailable(const std::string& version,
                                                const std::string& build,
                                                const std::string& url,
                                                const std::string& version_full) {
  auto event = MakeEvent("updateAvailable");
  event[flutter::EncodableValue("version")] = flutter::EncodableValue(version);
  event[flutter::EncodableValue("build")] = flutter::EncodableValue(build);
  event[flutter::EncodableValue("url")] = flutter::EncodableValue(url);
  event[flutter::EncodableValue("versionFull")] =
      flutter::EncodableValue(version_full);
  EmitMap(std::move(event));
}

void UpdaterEventPublisher::EmitNoUpdateAvailable(const std::string& version) {
  auto event = MakeEvent("noUpdateAvailable");
  event[flutter::EncodableValue("version")] = flutter::EncodableValue(version);
  EmitMap(std::move(event));
}

void UpdaterEventPublisher::EmitUpdateError(const std::string& code,
                                            const std::string& message) {
  auto event = MakeEvent("updateError");
  event[flutter::EncodableValue("code")] = flutter::EncodableValue(code);
  event[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
  EmitMap(std::move(event));
}

}  // namespace clingfy::bridge
