#include "Bridge/device_event_publisher.h"

#include <utility>

#include "Bridge/platform_thread_dispatcher.h"

namespace clingfy::bridge {

namespace {
constexpr const char* kAudioSourcesChanged = "audioSourcesChanged";
constexpr const char* kVideoSourcesChanged = "videoSourcesChanged";
constexpr const char* kDisplaysChanged = "displaysChanged";
constexpr const char* kAppWindowsChanged = "appWindowsChanged";
constexpr const char* kAudioOutputRouteChanged = "audioOutputRouteChanged";
}  // namespace

DeviceEventPublisher& DeviceEventPublisher::Instance() {
  static DeviceEventPublisher instance;
  return instance;
}

DeviceEventPublisher::DeviceEventPublisher() {
  worker_ = std::thread([this] { WorkerLoop(); });
}

DeviceEventPublisher::~DeviceEventPublisher() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
}

void DeviceEventPublisher::SetSink(std::unique_ptr<EventSink> sink) {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_ = std::move(sink);
}

void DeviceEventPublisher::ClearSink() {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_.reset();
}

bool DeviceEventPublisher::has_sink() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return sink_ != nullptr;
}

void DeviceEventPublisher::AddObserver(
    std::function<void(const std::string&)> observer) {
  if (!observer) {
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  observers_.push_back(std::move(observer));
}

void DeviceEventPublisher::ClearObservers() {
  std::lock_guard<std::mutex> lock(mutex_);
  observers_.clear();
}

void DeviceEventPublisher::SetDebounceForTesting(
    std::chrono::milliseconds interval) {
  std::lock_guard<std::mutex> lock(mutex_);
  debounce_ = interval;
}

int DeviceEventPublisher::EmitCountForTesting(const std::string& type) const {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = emit_counts_.find(type);
  return it == emit_counts_.end() ? 0 : it->second;
}

void DeviceEventPublisher::EmitAudioSourcesChanged() {
  Schedule(kAudioSourcesChanged);
}
void DeviceEventPublisher::EmitVideoSourcesChanged() {
  Schedule(kVideoSourcesChanged);
}
void DeviceEventPublisher::EmitDisplaysChanged() {
  Schedule(kDisplaysChanged);
}
void DeviceEventPublisher::EmitAppWindowsChanged() {
  Schedule(kAppWindowsChanged);
}
void DeviceEventPublisher::EmitAudioOutputRouteChanged() {
  Schedule(kAudioOutputRouteChanged);
}

void DeviceEventPublisher::Schedule(const std::string& type) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stop_) {
      return;
    }
    // Pushing the deadline OUT on every request is what makes this trailing
    // rather than leading: a burst collapses to one emit `debounce_` after the
    // burst ends, which is the state the caller actually wants Dart to read.
    pending_[type] = std::chrono::steady_clock::now() + debounce_;
  }
  cv_.notify_all();
}

void DeviceEventPublisher::WorkerLoop() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!stop_) {
    if (pending_.empty()) {
      cv_.wait(lock);
      continue;
    }
    // Wake at the EARLIEST outstanding deadline, not a fixed tick, so an
    // idle app costs nothing and a due event is never late.
    auto earliest = pending_.begin()->second;
    for (const auto& [type, deadline] : pending_) {
      (void)type;
      if (deadline < earliest) {
        earliest = deadline;
      }
    }
    if (cv_.wait_until(lock, earliest) == std::cv_status::no_timeout) {
      continue;  // a new request arrived (or stop) — re-evaluate deadlines
    }
    if (stop_) {
      break;
    }
    const auto now = std::chrono::steady_clock::now();
    std::vector<std::string> due;
    for (auto it = pending_.begin(); it != pending_.end();) {
      if (it->second <= now) {
        due.push_back(it->first);
        it = pending_.erase(it);
      } else {
        ++it;
      }
    }
    for (const std::string& type : due) {
      emit_counts_[type] += 1;
      // Release the lock across the dispatch: Post() reaches into the platform
      // thread, and an observer running under our own mutex would deadlock the
      // moment it asked this publisher anything.
      lock.unlock();
      DeliverOnPlatformThread(type);
      lock.lock();
    }
  }
}

void DeviceEventPublisher::DeliverOnPlatformThread(const std::string& type) {
  auto deliver = [this, type] {
    std::unique_ptr<EventSink>* sink_ptr = nullptr;
    std::vector<std::function<void(const std::string&)>> observers_copy;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      sink_ptr = &sink_;
      if (*sink_ptr != nullptr) {
        (*sink_ptr)->Success(flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
        }));
      }
      observers_copy = observers_;
    }
    // Observers run OUTSIDE the lock for the same reason as above.
    for (const auto& observer : observers_copy) {
      observer(type);
    }
  };

  // Before FlutterWindow initializes the dispatcher (and in headless tests)
  // there is no platform thread to marshal to; running inline is correct
  // there because no sink can be attached yet either.
  if (PlatformThreadDispatcher::Instance().is_initialized()) {
    PlatformThreadDispatcher::Instance().Post(std::move(deliver));
  } else {
    deliver();
  }
}

}  // namespace clingfy::bridge
