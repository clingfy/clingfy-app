#ifndef RUNNER_BRIDGE_DEVICES_VIDEO_SOURCE_ENUMERATOR_H_
#define RUNNER_BRIDGE_DEVICES_VIDEO_SOURCE_ENUMERATOR_H_

#include <vector>

#include "Bridge/Devices/device_record.h"

// Phase 2: real `getVideoSources` implementation.
//
// Enumerates video capture devices (built-in cameras, USB webcams,
// `OBS Virtual Camera`-style devices) via Media Foundation
// `MFEnumDeviceSources`.
//
// Each device becomes a `VideoSourceRecord`:
//   * `id`   — the device's `MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK`
//              string. Stable across boots, suitable for re-opening the
//              device in Phase 9.
//   * `name` — `MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME`. Falls back to a
//              generic "Camera" label so the picker never shows a blank
//              entry.
//
// MF startup is lazy: the first enumeration calls `MFStartup`. The matching
// `MFShutdown` is intentionally not paired here — repeated start/shutdown
// during normal device hot-plug events is more expensive than holding the
// MF subsystem open for the process lifetime, and a single non-balanced
// `MFStartup` is the documented pattern.
namespace clingfy::bridge::devices {

// `max_attempts` (Phase 10.2): the 3-attempt/200ms-sleep retry exists to
// ride out a Frame Server cold-start before CAPTURE. Informational callers
// (the permissions UI) pass 1 — on a camera-less machine the full retry
// budget would stall the platform thread ~400ms on every refresh/resume.
std::vector<VideoSourceRecord> EnumerateVideoInputs(int max_attempts = 3);

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_VIDEO_SOURCE_ENUMERATOR_H_
