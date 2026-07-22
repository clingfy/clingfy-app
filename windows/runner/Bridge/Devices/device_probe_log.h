#ifndef RUNNER_BRIDGE_DEVICES_DEVICE_PROBE_LOG_H_
#define RUNNER_BRIDGE_DEVICES_DEVICE_PROBE_LOG_H_

namespace clingfy::bridge::devices {

// Diagnostic breadcrumbs shared by the device enumerators, the camera
// overlay stack, and the recording engine. Forwards into the unified log
// pipeline as DEBUG lines under the "DeviceProbe" category
// (NativeLogPublisher → Dart JSONL file), so the Settings "verbose logging"
// toggle governs them like every other debug trace. Lines emitted before the
// Flutter channel attaches are held in the publisher's pending buffer and
// drained once Dart is ready.
//
// (Until the logging unification this wrote its own
// %LOCALAPPDATA%\Clingfy\Logs\device_probe.log side file — one mechanism,
// one file now.)
void LogDeviceProbe(const char* msg);

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_DEVICE_PROBE_LOG_H_
