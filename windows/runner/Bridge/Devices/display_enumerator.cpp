#include "Bridge/Devices/display_enumerator.h"

#include <windows.h>
#include <shellscalingapi.h>

#include <cstdint>
#include <string>
#include <unordered_map>
#include <utility>

#include "Bridge/Devices/display_label.h"

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

// Maps a GDI device name ("\\\\.\\DISPLAY1") to the EDID monitor friendly name
// ("DELL U2720Q") via the CCD API.
//
// `EnumDisplayDevicesW(...).DeviceString` is the *driver* name and is
// "Generic PnP Monitor" for most monitors, which identifies nothing. The CCD
// tables carry the real model. Built once per enumeration so the source and
// target tables are one consistent snapshot.
//
// No CMake change: GetDisplayConfigBufferSizes / QueryDisplayConfig /
// DisplayConfigGetDeviceInfo are declared in winuser.h and export from
// user32.dll, which MSVC links implicitly.
std::unordered_map<std::wstring, std::wstring> BuildCcdFriendlyNames() {
  UINT32 path_count = 0;
  UINT32 mode_count = 0;
  if (::GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count,
                                    &mode_count) != ERROR_SUCCESS) {
    return {};
  }
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
  if (::QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths.data(),
                           &mode_count, modes.data(),
                           nullptr) != ERROR_SUCCESS) {
    return {};
  }
  paths.resize(path_count);

  std::unordered_map<std::wstring, std::pair<UINT32, std::wstring>> best;
  for (const auto& path : paths) {
    DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
    source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    source.header.size = sizeof(source);
    source.header.adapterId = path.sourceInfo.adapterId;
    source.header.id = path.sourceInfo.id;
    if (::DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS) {
      continue;
    }

    DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
    target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
    target.header.size = sizeof(target);
    target.header.adapterId = path.targetInfo.adapterId;
    target.header.id = path.targetInfo.id;
    if (::DisplayConfigGetDeviceInfo(&target.header) != ERROR_SUCCESS) {
      continue;
    }
    if (target.monitorFriendlyDeviceName[0] == L'\0') {
      continue;  // Virtual / remote displays legitimately have none.
    }

    const std::wstring key(source.viewGdiDeviceName);
    // A CLONE set puts several targets on one source. Lowest targetInfo.id
    // wins — a stable identity, so the name cannot flicker between
    // enumerations.
    auto it = best.find(key);
    if (it == best.end() || path.targetInfo.id < it->second.first) {
      best[key] = {path.targetInfo.id,
                   std::wstring(target.monitorFriendlyDeviceName)};
    }
  }

  std::unordered_map<std::wstring, std::wstring> out;
  for (auto& entry : best) {
    out.emplace(entry.first, entry.second.second);
  }
  return out;
}

struct EnumCtx {
  std::vector<DisplayRecord>* out = nullptr;
  const std::unordered_map<std::wstring, std::wstring>* ccd = nullptr;
};

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
  auto* ctx = reinterpret_cast<EnumCtx*>(user_data);

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
  record.is_primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
  record.is_app_window_host = false;  // v1: Windows has no host marker.

  // Name ladder: CCD friendly name -> driver DeviceString -> empty. Each rung
  // is rejected if it is a known placeholder, so an unusable name becomes an
  // absent one rather than a misleading one.
  std::string candidate;
  if (ctx->ccd != nullptr) {
    const auto it = ctx->ccd->find(info.szDevice);
    if (it != ctx->ccd->end()) {
      candidate = Utf8FromWide(it->second);
    }
  }
  if (candidate.empty() || IsGenericMonitorName(candidate)) {
    DISPLAY_DEVICEW name_device{};
    name_device.cb = sizeof(name_device);
    candidate.clear();
    if (::EnumDisplayDevicesW(info.szDevice, 0, &name_device,
                              EDD_GET_DEVICE_INTERFACE_NAME)) {
      const std::string driver_name = Utf8FromWide(name_device.DeviceString);
      if (!IsGenericMonitorName(driver_name)) {
        candidate = driver_name;
      }
    }
  }
  record.os_name = NormalizeMonitorName(candidate);

  // ID: UNCHANGED SEMANTICS, and deliberately NOT sharing a DISPLAY_DEVICEW
  // with the name ladder above — that ladder may short-circuit, which would
  // silently switch the hash source from DeviceID to szDevice, diverge from
  // ComputeIdForMonitor, and invalidate every user's persisted
  // 'selectedDisplayId'.
  DISPLAY_DEVICEW id_device{};
  id_device.cb = sizeof(id_device);
  ::EnumDisplayDevicesW(info.szDevice, 0, &id_device,
                        EDD_GET_DEVICE_INTERFACE_NAME);
  const std::wstring id_source = id_device.DeviceID[0] != L'\0'
                                     ? std::wstring(id_device.DeviceID)
                                     : std::wstring(info.szDevice);
  record.id = HashDevicePath(id_source);

  ctx->out->push_back(std::move(record));
  return TRUE;
}

}  // namespace

std::vector<DisplayRecord> EnumerateDisplays() {
  const auto ccd = BuildCcdFriendlyNames();
  std::vector<DisplayRecord> raw;
  EnumCtx ctx{&raw, &ccd};
  ::EnumDisplayMonitors(nullptr, nullptr, &MonitorEnumProc,
                        reinterpret_cast<LPARAM>(&ctx));

  std::vector<OrderingInput> ordering;
  ordering.reserve(raw.size());
  for (const auto& record : raw) {
    ordering.push_back({record.id, record.x, record.y});
  }
  const auto order = OrderedIndices(ordering);

  std::vector<DisplayRecord> out;
  out.reserve(order.size());
  for (std::size_t position = 0; position < order.size(); ++position) {
    DisplayRecord record = raw[order[position]];
    record.ordinal = static_cast<std::int64_t>(position) + 1;
    // "Screen" is English on purpose: Windows has no NativeStringsStore, and
    // Dart never renders this fallback — an empty os_name is absent on the
    // wire, so DisplayLabelBuilder substitutes the localized word. This string
    // reaches only the native pre-recording bar and the diagnostics bundle.
    record.name = ComposeDisplayName(record.os_name, record.ordinal, "Screen");
    out.push_back(std::move(record));
  }
  return out;
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
