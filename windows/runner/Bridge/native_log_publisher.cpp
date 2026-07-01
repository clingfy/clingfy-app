#include "Bridge/native_log_publisher.h"

#include <cstdio>
#include <ctime>
#include <memory>

#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

namespace {

std::string NowUtcIso8601() {
  std::time_t now = std::time(nullptr);
  std::tm tm_utc{};
#if defined(_MSC_VER)
  ::gmtime_s(&tm_utc, &now);
#else
  tm_utc = *std::gmtime(&now);
#endif
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02dZ",
                tm_utc.tm_year + 1900, tm_utc.tm_mon + 1, tm_utc.tm_mday,
                tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec);
  return buf;
}

}  // namespace

NativeLogPublisher& NativeLogPublisher::Instance() {
  static NativeLogPublisher instance;
  return instance;
}

void NativeLogPublisher::SetChannel(
    flutter::MethodChannel<flutter::EncodableValue>* channel) {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = channel;
}

void NativeLogPublisher::ClearChannel() {
  std::lock_guard<std::mutex> lock(mutex_);
  channel_ = nullptr;
}

void NativeLogPublisher::Info(const std::string& category,
                              const std::string& message) {
  Emit("INFO", category, message);
}

void NativeLogPublisher::Warn(const std::string& category,
                              const std::string& message) {
  Emit("WARNING", category, message);
}

void NativeLogPublisher::Error(const std::string& category,
                               const std::string& message) {
  Emit("ERROR", category, message);
}

flutter::EncodableMap NativeLogPublisher::BuildPayload(
    const std::string& level, const std::string& category,
    const std::string& message, const std::string& ts_iso8601) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("ts"), flutter::EncodableValue(ts_iso8601)},
      {flutter::EncodableValue("level"), flutter::EncodableValue(level)},
      {flutter::EncodableValue("category"),
       flutter::EncodableValue(category)},
      {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
      {flutter::EncodableValue("context"),
       flutter::EncodableValue(flutter::EncodableMap{})},
  };
}

void NativeLogPublisher::Emit(const char* level, const std::string& category,
                              const std::string& message) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr) {
      return;  // no listener / torn down
    }
  }
  // Stamp the timestamp at emit time (not delivery time) so reordering on
  // the platform-thread queue can't skew the log order story.
  flutter::EncodableMap payload =
      BuildPayload(level, category, message, NowUtcIso8601());
  // Marshal to the platform thread; re-check the channel inside the posted
  // task so teardown mid-flight can't call into a dead channel.
  PlatformThreadDispatcher::Instance().Post([this, payload] {
    flutter::MethodChannel<flutter::EncodableValue>* channel_snapshot =
        nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      channel_snapshot = channel_;
    }
    if (channel_snapshot == nullptr) {
      return;
    }
    channel_snapshot->InvokeMethod(
        "log", std::make_unique<flutter::EncodableValue>(payload));
  });
}

}  // namespace clingfy::bridge
