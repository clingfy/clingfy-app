#ifndef RUNNER_BRIDGE_DEVICES_DEVICE_CHANGE_WATCHER_H_
#define RUNNER_BRIDGE_DEVICES_DEVICE_CHANGE_WATCHER_H_

#include <windows.h>

#include <memory>

// The OS side of device hot-plug: turns Windows' push notifications into
// DeviceEventPublisher emits.
//
// Three sources, because Windows has no single one:
//
//   * AUDIO — WASAPI `IMMNotificationClient`, registered on an
//     IMMDeviceEnumerator. Covers add / remove / state change / default
//     change for both capture and render endpoints. The default-render
//     change also feeds `audioOutputRouteChanged`, which the speaker-bleed
//     warning has been waiting on.
//
//   * CAMERAS — `RegisterDeviceNotification` for KSCATEGORY_VIDEO_CAMERA on a
//     message-only window, handled via WM_DEVICECHANGE. WASAPI's notification
//     client says nothing about video devices.
//
//   * DISPLAYS — WM_DISPLAYCHANGE on the same message-only window. (An
//     existing WM_DISPLAYCHANGE handler lives on the identify-badge overlay,
//     but that one only destroys its own window and notifies nobody, so it
//     cannot be reused.)
//
// A message-only window is used rather than hanging these off the Flutter
// window so the watcher owns its own lifetime and can be started before, and
// torn down independently of, any UI.
//
// Every callback here arrives on a non-platform thread (COM worker threads for
// WASAPI; the watcher's own thread for the window). Nothing in this file
// touches a Flutter sink — it all goes through DeviceEventPublisher, which
// debounces and marshals.
namespace clingfy::bridge::devices {

class DeviceChangeWatcher {
 public:
  static DeviceChangeWatcher& Instance();

  DeviceChangeWatcher(const DeviceChangeWatcher&) = delete;
  DeviceChangeWatcher& operator=(const DeviceChangeWatcher&) = delete;

  // Register every listener. Idempotent; safe to call when some sources fail
  // (a machine with no audio endpoints still gets camera + display events).
  // Returns false only when NOTHING could be registered.
  bool Start();

  // Unregister and tear down. Idempotent.
  void Stop();

  bool running() const;

 private:
  DeviceChangeWatcher();
  ~DeviceChangeWatcher();

  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_DEVICE_CHANGE_WATCHER_H_
