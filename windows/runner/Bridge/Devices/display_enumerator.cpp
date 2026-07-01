#include "Bridge/Devices/display_enumerator.h"

#include <windows.h>
#include <shellscalingapi.h>

#include <cstdint>
#include <string>

namespace clingfy::bridge::devices {

namespace {

// Convert a wide string to UTF-8. Used for monitor friendly names which the
// Win32 API returns as `WCHAR[]`. An empty input yields an empty string.
std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) {
    return {};
  }
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) {
    return {};
  }
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                        static_cast<int>(wide.size()), out.data(), needed,
                        nullptr, nullptr);
  return out;
}

// FNV-1a 32-bit hash over the device path. Two monitors of the same model
// have different `DeviceID` strings (they include the adapter LUID), so this
// is sufficient for in-session uniqueness without leaking PII.
std::int64_t HashDevicePath(const std::wstring& path) {
  constexpr std::uint32_t kOffset = 2166136261u;
  constexpr std::uint32_t kPrime = 16777619u;
  std::uint32_t hash = kOffset;
  for (wchar_t ch : path) {
    hash ^= static_cast<std::uint32_t>(ch);
    hash *= kPrime;
  }
  // Cast to signed 64-bit so the Flutter Standard codec sends it as an Int64
  // and the Dart `(m['id'] as num).toInt()` parse round-trips correctly.
  return static_cast<std::int64_t>(hash);
}

// Per-monitor DPI scale where 96 DPI == 1.0. Falls back to 1.0 if the system
// is older than Windows 8.1 or the call fails for any other reason.
double ScaleForMonitor(HMONITOR monitor) {
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  const HRESULT hr =
      ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  if (FAILED(hr) || dpi_x == 0) {
    return 1.0;
  }
  return static_cast<double>(dpi_x) / 96.0;
}

// Computes the hashed id that `EnumerateDisplays` would assign to this
// monitor. Kept as a free function so `ResolveHMonitor` can recompute the
// id for each HMONITOR without re-running the full enumeration.
std::int64_t ComputeIdForMonitor(HMONITOR monitor) {
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return 0;
  }
  DISPLAY_DEVICEW device{};
  device.cb = sizeof(device);
  const bool ok = ::EnumDisplayDevicesW(info.szDevice, 0, &device,
                                         EDD_GET_DEVICE_INTERFACE_NAME) != 0;
  const std::wstring id_source =
      (ok && device.DeviceID[0] != L'\0') ? std::wstring(device.DeviceID)
                                          : std::wstring(info.szDevice);
  return HashDevicePath(id_source);
}

struct MatchContext {
  std::int64_t target_id = 0;
  HMONITOR match = nullptr;
};

BOOL CALLBACK MatchMonitorEnumProc(HMONITOR monitor,
                                   HDC /*hdc*/,
                                   LPRECT /*clip*/,
                                   LPARAM user_data) {
  auto* ctx = reinterpret_cast<MatchContext*>(user_data);
  if (ComputeIdForMonitor(monitor) == ctx->target_id) {
    ctx->match = monitor;
    return FALSE;  // Stop enumeration on the first match.
  }
  return TRUE;
}

BOOL CALLBACK MonitorEnumProc(HMONITOR monitor,
                              HDC /*hdc*/,
                              LPRECT /*clip*/,
                              LPARAM user_data) {
  auto* out = reinterpret_cast<std::vector<DisplayRecord>*>(user_data);

  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return TRUE;  // Skip this monitor, keep enumerating.
  }

  DisplayRecord record;
  record.x = static_cast<double>(info.rcMonitor.left);
  record.y = static_cast<double>(info.rcMonitor.top);
  record.width =
      static_cast<double>(info.rcMonitor.right - info.rcMonitor.left);
  record.height =
      static_cast<double>(info.rcMonitor.bottom - info.rcMonitor.top);
  record.scale = ScaleForMonitor(monitor);

  // Friendly name: prefer the registry-display name resolved via
  // `EnumDisplayDevicesW`. `MONITORINFOEXW::szDevice` is the GDI device path
  // (e.g. "\\\\.\\DISPLAY1"), which is not user-friendly.
  DISPLAY_DEVICEW device{};
  device.cb = sizeof(device);
  std::wstring friendly;
  if (::EnumDisplayDevicesW(info.szDevice, 0, &device,
                            EDD_GET_DEVICE_INTERFACE_NAME)) {
    friendly = device.DeviceString;
  }
  if (friendly.empty()) {
    friendly = info.szDevice;
  }
  record.name = Utf8FromWide(friendly);

  // Stable-ish id derived from the device interface path. Falls back to the
  // GDI device path if no interface name is available.
  const std::wstring id_source = device.DeviceID[0] != L'\0'
                                     ? std::wstring(device.DeviceID)
                                     : std::wstring(info.szDevice);
  record.id = HashDevicePath(id_source);

  out->push_back(std::move(record));
  return TRUE;
}

}  // namespace

std::vector<DisplayRecord> EnumerateDisplays() {
  std::vector<DisplayRecord> displays;
  ::EnumDisplayMonitors(nullptr, nullptr, &MonitorEnumProc,
                        reinterpret_cast<LPARAM>(&displays));
  return displays;
}

std::optional<HMONITOR> ResolveHMonitor(std::optional<std::int64_t> id) {
  if (!id) {
    // No explicit selection — use the primary monitor as the friendly
    // default. `MonitorFromPoint` with (0, 0) and DEFAULTTOPRIMARY is the
    // documented way to fetch the primary monitor handle without iterating.
    const POINT origin{0, 0};
    HMONITOR primary = ::MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
    if (primary == nullptr) {
      return std::nullopt;
    }
    return primary;
  }

  MatchContext ctx;
  ctx.target_id = *id;
  ::EnumDisplayMonitors(nullptr, nullptr, &MatchMonitorEnumProc,
                        reinterpret_cast<LPARAM>(&ctx));
  if (ctx.match == nullptr) {
    return std::nullopt;
  }
  return ctx.match;
}

}  // namespace clingfy::bridge::devices
