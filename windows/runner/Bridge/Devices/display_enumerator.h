#ifndef RUNNER_BRIDGE_DEVICES_DISPLAY_ENUMERATOR_H_
#define RUNNER_BRIDGE_DEVICES_DISPLAY_ENUMERATOR_H_

#include <vector>

#include "Bridge/Devices/device_record.h"

// Phase 2: real `getDisplays` implementation.
//
// Walks the active monitors via `EnumDisplayMonitors`, reads each monitor's
// virtual-screen rectangle, friendly name, and per-monitor DPI scale, and
// returns a vector of `DisplayRecord` ready to be converted to the
// EncodableList shape the Dart `DisplayInfo.fromMap` parser expects.
//
// Coordinates are in virtual-screen pixels (origin at the top-left of the
// primary monitor's working area; secondary monitors can have negative
// values). This matches what the macOS engine reports.
//
// IDs are stable for the lifetime of a session but not across sessions —
// Windows does not expose a permanent monitor identifier that survives
// docking / undocking. The current implementation derives an id from the
// monitor's device path hash so that two monitors with the same model do
// not collide.
namespace clingfy::bridge::devices {

std::vector<DisplayRecord> EnumerateDisplays();

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_DISPLAY_ENUMERATOR_H_
