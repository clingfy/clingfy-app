#ifndef RUNNER_BRIDGE_DEVICES_DISPLAY_LABEL_H_
#define RUNNER_BRIDGE_DEVICES_DISPLAY_LABEL_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace clingfy::bridge::devices {

// Pure display ordering + labelling. No Win32 call lives in here, so it is
// unit-testable without hardware.
//
// Mirrored in macos/Runner/Platform/DisplayService.swift (`DisplayLabeler`) —
// the two must produce identical strings for identical input, and each side's
// test suite asserts the same literal outputs so a drift turns one of them red.

struct OrderingInput {
  std::int64_t id = 0;
  double x = 0.0;
  double y = 0.0;
};

// Total order: x ascending, then y ascending, then id ascending. Returns
// indices into `in`; position p carries ordinal p + 1.
//
// The sort key is desktop geometry rather than the OS enumeration order, so
// two enumerations of an unchanged display configuration produce identical
// ordinals however EnumDisplayMonitors happened to walk the monitors.
std::vector<std::size_t> OrderedIndices(const std::vector<OrderingInput>& in);

// True for names an inbox driver hands back that identify nothing:
// "", "display", "unknown", "unknown display", "generic pnp monitor",
// "generic non-pnp monitor", "default monitor". Compared trimmed and
// ASCII-lowercased.
bool IsGenericMonitorName(const std::string& utf8);

// Trim, then collapse internal whitespace runs to a single space.
std::string NormalizeMonitorName(const std::string& utf8);

// "<ordinal>. <os_name.empty() ? screen_word : os_name>"
std::string ComposeDisplayName(const std::string& os_name,
                               std::int64_t ordinal,
                               const std::string& screen_word);

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_DISPLAY_LABEL_H_
