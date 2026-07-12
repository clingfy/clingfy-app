#include "Bridge/native_log_publisher.h"

#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <memory>
#include <utility>
#include <vector>

#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

namespace {

// Rank for a level NAME Dart sends down (debug/info/warning/error, plus the
// short + verbose aliases), or -1 for unknown. Mirrors macOS NativeLogger.
int RankForLevelName(const std::string& name) {
  std::string n;
  n.reserve(name.size());
  for (const char c : name) {
    if (!std::isspace(static_cast<unsigned char>(c))) {
      n += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
  }
  if (n == "debug" || n == "d" || n == "verbose" || n == "trace") return 0;
  if (n == "info" || n == "i") return 1;
  if (n == "warning" || n == "warn" || n == "w") return 2;
  if (n == "error" || n == "e") return 3;
  return -1;
}

// Rank for an EMITTED level constant ("DEBUG"/"INFO"/"WARNING"/"ERROR").
int RankForEmittedLevel(const std::string& level) {
  if (level == "INFO") return 1;
  if (level == "WARNING") return 2;
  if (level == "ERROR") return 3;
  return 0;  // DEBUG / unknown
}

// Env override (CLINGFY_LOG_LEVEL, matching the Dart Log.logLevelEnvVar) > build
// default (Debug build → debug, Release → info). Resolved once at construction.
int ResolveDefaultRank() {
#if defined(_MSC_VER)
  char buf[32];
  std::size_t len = 0;
  if (::getenv_s(&len, buf, sizeof(buf), "CLINGFY_LOG_LEVEL") == 0 && len > 0) {
    const int rank = RankForLevelName(buf);
    if (rank >= 0) return rank;
  }
#else
  if (const char* raw = std::getenv("CLINGFY_LOG_LEVEL")) {
    const int rank = RankForLevelName(raw);
    if (rank >= 0) return rank;
  }
#endif
#if defined(_DEBUG)
  return 0;  // debug build
#else
  return 1;  // info
#endif
}

// UTC ISO8601 with millisecond precision and a trailing 'Z' — the shared
// cross-platform timestamp base (Dart Log and macOS NativeLogger emit the
// same shape), so one JSONL file sorts on one clock.
std::string NowUtcIso8601() {
  const auto now = std::chrono::system_clock::now();
  const std::time_t seconds = std::chrono::system_clock::to_time_t(now);
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      now.time_since_epoch())
                      .count() %
                  1000;
  std::tm tm_utc{};
#if defined(_MSC_VER)
  ::gmtime_s(&tm_utc, &seconds);
#else
  tm_utc = *std::gmtime(&seconds);
#endif
  char buf[40];
  std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                tm_utc.tm_year + 1900, tm_utc.tm_mon + 1, tm_utc.tm_mday,
                tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec,
                static_cast<int>(ms));
  return buf;
}

}  // namespace

NativeLogPublisher::NativeLogPublisher()
    : min_level_rank_(ResolveDefaultRank()) {}

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

void NativeLogPublisher::Debug(const std::string& category,
                               const std::string& message,
                               flutter::EncodableMap context) {
  Emit("DEBUG", category, message, std::move(context));
}

void NativeLogPublisher::Info(const std::string& category,
                              const std::string& message,
                              flutter::EncodableMap context) {
  Emit("INFO", category, message, std::move(context));
}

void NativeLogPublisher::SetMinLevel(const std::string& level_name) {
  const int rank = RankForLevelName(level_name);
  if (rank >= 0) {
    min_level_rank_.store(rank);
  }
}

bool NativeLogPublisher::ShouldSend(const std::string& emitted_level) const {
  return RankForEmittedLevel(emitted_level) >= min_level_rank_.load();
}

void NativeLogPublisher::Warn(const std::string& category,
                              const std::string& message,
                              flutter::EncodableMap context) {
  Emit("WARNING", category, message, std::move(context));
}

void NativeLogPublisher::Error(const std::string& category,
                               const std::string& message,
                               flutter::EncodableMap context,
                               const std::string& error_text,
                               const std::string& stack) {
  Emit("ERROR", category, message, std::move(context), error_text, stack);
}

flutter::EncodableMap NativeLogPublisher::BuildPayload(
    const std::string& level, const std::string& category,
    const std::string& message, const std::string& ts_iso8601,
    flutter::EncodableMap context, const std::string& error_text,
    const std::string& stack) {
  flutter::EncodableMap payload{
      {flutter::EncodableValue("ts"), flutter::EncodableValue(ts_iso8601)},
      {flutter::EncodableValue("level"), flutter::EncodableValue(level)},
      {flutter::EncodableValue("category"),
       flutter::EncodableValue(category)},
      {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
      {flutter::EncodableValue("context"),
       flutter::EncodableValue(std::move(context))},
  };
  // Optional keys travel only when set — Dart's parser nulls empty strings
  // anyway, and the JSONL line stays free of null padding.
  if (!error_text.empty()) {
    payload[flutter::EncodableValue("error")] =
        flutter::EncodableValue(error_text);
  }
  if (!stack.empty()) {
    payload[flutter::EncodableValue("stack")] = flutter::EncodableValue(stack);
  }
  return payload;
}

void NativeLogPublisher::Emit(const char* level, const std::string& category,
                              const std::string& message,
                              flutter::EncodableMap context,
                              const std::string& error_text,
                              const std::string& stack) {
  // Drop below-threshold logs at the SOURCE so they never cross the channel or
  // reach release users' logs/Sentry (mirrors macOS NativeLogger.send).
  if (!ShouldSend(level)) {
    return;
  }
  // Stamp the timestamp at emit time (not delivery time) so buffering or
  // reordering on the platform-thread queue can't skew the log order story.
  flutter::EncodableMap payload =
      BuildPayload(level, category, message, NowUtcIso8601(),
                   std::move(context), error_text, stack);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr) {
      // No listener yet (startup) or already torn down: hold the line for
      // the flushPendingNativeLogs drain instead of dropping it.
      if (pending_.size() >= kMaxPending) {
        pending_.pop_front();
      }
      pending_.push_back(std::move(payload));
      return;
    }
  }
  PostToChannel(std::move(payload));
}

void NativeLogPublisher::FlushPending() {
  std::vector<flutter::EncodableMap> drained;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == nullptr || pending_.empty()) {
      return;  // keep the buffer — a later flush may still deliver it
    }
    drained.assign(std::make_move_iterator(pending_.begin()),
                   std::make_move_iterator(pending_.end()));
    pending_.clear();
  }
  for (auto& payload : drained) {
    PostToChannel(std::move(payload));
  }
}

size_t NativeLogPublisher::pending_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return pending_.size();
}

void NativeLogPublisher::ClearPendingForTest() {
  std::lock_guard<std::mutex> lock(mutex_);
  pending_.clear();
}

flutter::EncodableMap NativeLogPublisher::FrontPendingForTest() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return pending_.empty() ? flutter::EncodableMap{} : pending_.front();
}

void NativeLogPublisher::PostToChannel(flutter::EncodableMap payload) {
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
