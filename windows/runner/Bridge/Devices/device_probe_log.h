#ifndef RUNNER_BRIDGE_DEVICES_DEVICE_PROBE_LOG_H_
#define RUNNER_BRIDGE_DEVICES_DEVICE_PROBE_LOG_H_

namespace clingfy::bridge::devices {

// Append-only diagnostic log shared by the device enumerators and the
// recording engine's audio-start path. Writes one timestamped line to
// `build/windows-poc/device_probe.log`. Best-effort: silent if the file
// cannot be opened (no exception propagates), since these are diagnostic
// breadcrumbs, not load-bearing.
void LogDeviceProbe(const char* msg);

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_DEVICE_PROBE_LOG_H_
