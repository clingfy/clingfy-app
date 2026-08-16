#ifndef RUNNER_BRIDGE_DEVICE_EVENT_PUBLISHER_H_
#define RUNNER_BRIDGE_DEVICE_EVENT_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>

#include <chrono>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Process-level publisher for the device half of
// `com.clingfy/screen_recorder/events`, replacing the Phase-0
// NoopStreamHandler that had served that channel since the port began.
//
// Dart has been fully wired for this the whole time and simply never heard
// anything: `DeviceController` subscribes and handles `audioSourcesChanged`,
// `videoSourcesChanged`, `displaysChanged` and `appWindowsChanged`, and
// `RecordingSettingsController` subscribes for `audioOutputRouteChanged`.
// There is no polling fallback anywhere — the only other refresh paths are
// initial hydration and a manual keyboard shortcut — so before this, plugging
// in a microphone mid-session left every device list stale until the user
// noticed and refreshed by hand.
//
// DEBOUNCED, and not optionally. A single dock connect or monitor wake fires a
// burst of OS notifications; forwarding each one makes Dart re-enumerate audio
// endpoints N times in a few milliseconds. macOS learned this and coalesces on
// a 0.25 s trailing debouncer (`AudioHardwareListener.swift`), so this matches
// that interval and that shape: the LAST event in a burst wins, one emit per
// quiet period per event type.
//
// THREADING. WASAPI's IMMNotificationClient callbacks arrive on COM worker
// threads and WM_DEVICECHANGE on whichever thread owns the listening window,
// so nothing here may touch the sink directly — every emit is marshalled to
// the platform thread through PlatformThreadDispatcher, which is the same rule
// every other publisher in this directory follows.
namespace clingfy::bridge {

class DeviceEventPublisher {
 public:
  using EventSink = flutter::EventSink<flutter::EncodableValue>;

  static DeviceEventPublisher& Instance();

  DeviceEventPublisher(const DeviceEventPublisher&) = delete;
  DeviceEventPublisher& operator=(const DeviceEventPublisher&) = delete;

  void SetSink(std::unique_ptr<EventSink> sink);
  void ClearSink();
  bool has_sink() const;

  // The five payload types Dart already handles. Each is independently
  // debounced, so an audio burst cannot swallow a display change.
  void EmitAudioSourcesChanged();
  void EmitVideoSourcesChanged();
  void EmitDisplaysChanged();
  void EmitAppWindowsChanged();
  void EmitAudioOutputRouteChanged();

  // Fan-out for native surfaces that must refresh themselves rather than wait
  // for Dart — the pre-recording bar's device popover is the case that exists
  // (macOS solves the same problem with a second NSNotification fan-out, since
  // the Flutter sink is single-assignment). Observers run on the platform
  // thread, after debouncing, alongside the Dart emit.
  void AddObserver(std::function<void(const std::string& type)> observer);
  void ClearObservers();

  // Test seam: shorten the debounce so coalescing can be asserted without a
  // quarter-second sleep in every case.
  void SetDebounceForTesting(std::chrono::milliseconds interval);

  // Test seam: how many times each type has actually reached the emit stage,
  // which is what "coalesced" means observationally.
  int EmitCountForTesting(const std::string& type) const;

  ~DeviceEventPublisher();

 private:
  DeviceEventPublisher();

  // Schedule `type` for emission once `debounce_` has passed with no further
  // request for that same type.
  void Schedule(const std::string& type);
  void WorkerLoop();
  void DeliverOnPlatformThread(const std::string& type);

  mutable std::mutex mutex_;
  std::unique_ptr<EventSink> sink_;
  std::vector<std::function<void(const std::string&)>> observers_;

  // type -> the deadline at which it should fire. Re-requesting a type before
  // its deadline pushes the deadline out; that is what makes it TRAILING.
  std::map<std::string, std::chrono::steady_clock::time_point> pending_;
  std::map<std::string, int> emit_counts_;
  std::chrono::milliseconds debounce_{250};

  std::condition_variable cv_;
  bool stop_ = false;
  std::thread worker_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_DEVICE_EVENT_PUBLISHER_H_
