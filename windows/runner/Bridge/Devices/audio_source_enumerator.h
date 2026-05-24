#ifndef RUNNER_BRIDGE_DEVICES_AUDIO_SOURCE_ENUMERATOR_H_
#define RUNNER_BRIDGE_DEVICES_AUDIO_SOURCE_ENUMERATOR_H_

#include <vector>

#include "Bridge/Devices/device_record.h"

// Phase 2: real `getAudioSources` implementation.
//
// Enumerates active audio *capture* endpoints (microphones, line-ins) via
// the WASAPI `IMMDeviceEnumerator` interface. System audio (loopback) is
// out of scope here — that lives behind `setAudioMix` and lands with the
// recording engine in Phase 3.
//
// Each endpoint becomes an `AudioSourceRecord`:
//   * `id`   — the WASAPI endpoint id string (stable across boots).
//   * `name` — the property-store friendly name; falls back to the device
//              description if PKEY_Device_FriendlyName is unavailable.
//
// The enumerator initializes COM on the calling thread (APARTMENTTHREADED)
// if it has not been initialized already, and tolerates the
// `RPC_E_CHANGED_MODE` case where COM is already initialized in a
// different mode (we just continue and trust the existing initialization).
namespace clingfy::bridge::devices {

std::vector<AudioSourceRecord> EnumerateAudioInputs();

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_AUDIO_SOURCE_ENUMERATOR_H_
