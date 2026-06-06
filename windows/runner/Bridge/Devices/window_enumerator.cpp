#include "Bridge/Devices/window_enumerator.h"

#include <windows.h>
#include <dwmapi.h>
#include <psapi.h>
#include <shellscalingapi.h>

#include <cstdint>
#include <filesystem>
#include <string>

namespace clingfy::bridge::devices {

namespace {

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

std::wstring GetWindowTitle(HWND hwnd) {
  const int len = ::GetWindowTextLengthW(hwnd);
  if (len <= 0) {
    return {};
  }
  std::wstring title(static_cast<size_t>(len) + 1, L'\0');
  const int written =
      ::GetWindowTextW(hwnd, title.data(), static_cast<int>(title.size()));
  if (written <= 0) {
    return {};
  }
  title.resize(static_cast<size_t>(written));
  return title;
}

// Resolve the executable basename for the window's owning process. This is
// the display fallback when DWM/GDI don't surface a user-friendly app name
// (which is the common case for non-UWP desktop apps).
std::wstring GetProcessExecutableName(DWORD pid) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return {};
  }
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD size = static_cast<DWORD>(buffer.size());
  std::wstring exe;
  if (::QueryFullProcessImageNameW(process, 0, buffer.data(), &size)) {
    buffer.resize(size);
    std::filesystem::path path(buffer);
    exe = path.stem().wstring();
  }
  ::CloseHandle(process);
  return exe;
}

bool IsCloaked(HWND hwnd) {
  BOOL cloaked = FALSE;
  const HRESULT hr = ::DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                              sizeof(cloaked));
  return SUCCEEDED(hr) && cloaked != FALSE;
}

bool TryExtendedFrameBounds(HWND hwnd, RECT& out) {
  RECT extended{};
  const HRESULT hr = ::DwmGetWindowAttribute(
      hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &extended, sizeof(extended));
  if (FAILED(hr)) {
    return false;
  }
  out = extended;
  return true;
}

std::int64_t DisplayIdForWindow(HWND hwnd) {
  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr) {
    return 0;
  }
  // Cast the HMONITOR pointer to an integer so the Dart side has a
  // session-stable identifier. Phase 3 may want to cross-reference this
  // against `getDisplays` ids; for now they are intentionally distinct
  // numbers so a naive equality check does not produce false positives.
  return static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(monitor));
}

BOOL CALLBACK WindowEnumProc(HWND hwnd, LPARAM user_data) {
  auto* out = reinterpret_cast<std::vector<AppWindowRecord>*>(user_data);

  if (!::IsWindowVisible(hwnd)) {
    return TRUE;
  }
  if (IsCloaked(hwnd)) {
    return TRUE;
  }
  // Only top-level windows (no children, no owned popups) appear in the
  // picker. `GetAncestor(..., GA_ROOTOWNER)` returning the same HWND is the
  // canonical test.
  if (::GetAncestor(hwnd, GA_ROOTOWNER) != hwnd) {
    return TRUE;
  }
  // Tool windows are typically palettes / floaters that the user does not
  // want to record on their own.
  const LONG_PTR ex_style = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if ((ex_style & WS_EX_TOOLWINDOW) != 0) {
    return TRUE;
  }

  const std::wstring title = GetWindowTitle(hwnd);

  RECT rect{};
  const bool has_bounds = TryExtendedFrameBounds(hwnd, rect) ||
                          (::GetWindowRect(hwnd, &rect) != 0);
  if (has_bounds) {
    const LONG width = rect.right - rect.left;
    const LONG height = rect.bottom - rect.top;
    if (width <= 1 || height <= 1) {
      return TRUE;
    }
  }

  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);

  // Untitled windows are dropped unless the executable name lets us at least
  // label them. This keeps invisible shell helper windows out of the picker.
  const std::wstring app_name = GetProcessExecutableName(pid);
  if (title.empty() && app_name.empty()) {
    return TRUE;
  }

  AppWindowRecord record;
  record.window_id =
      static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(hwnd));
  record.app_name = Utf8FromWide(app_name);
  record.title = Utf8FromWide(title);
  if (has_bounds) {
    record.bounds_x = static_cast<double>(rect.left);
    record.bounds_y = static_cast<double>(rect.top);
    record.bounds_width = static_cast<double>(rect.right - rect.left);
    record.bounds_height = static_cast<double>(rect.bottom - rect.top);
  }
  record.display_id = DisplayIdForWindow(hwnd);
  record.pid = static_cast<std::int64_t>(pid);

  out->push_back(std::move(record));
  return TRUE;
}

}  // namespace

std::vector<AppWindowRecord> EnumerateAppWindows() {
  std::vector<AppWindowRecord> windows;
  ::EnumWindows(&WindowEnumProc, reinterpret_cast<LPARAM>(&windows));
  return windows;
}

std::optional<HWND> ResolveAppWindow(std::optional<std::int64_t> id) {
  if (!id.has_value()) {
    return std::nullopt;
  }
  // EnumerateAppWindows encodes the HWND as `window_id` via
  // reinterpret_cast<std::uintptr_t>; reverse it and confirm the handle still
  // names a live window. (HWNDs are only session-stable; a stale id from a
  // closed window resolves to nullopt rather than a dangling handle.)
  HWND hwnd = reinterpret_cast<HWND>(static_cast<std::uintptr_t>(*id));
  if (::IsWindow(hwnd) == 0) {
    return std::nullopt;
  }
  return hwnd;
}

}  // namespace clingfy::bridge::devices
