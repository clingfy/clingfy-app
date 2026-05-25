#include "Permissions/permission_probe.h"

#include <windows.h>
#include <shellapi.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Authorization.AppCapabilityAccess.h>

namespace clingfy::permissions {

namespace {

namespace cap = winrt::Windows::Security::Authorization::AppCapabilityAccess;

// Probe a single capability via `AppCapability::Create`. The WinRT
// helper inspects both the global "allow desktop apps" toggle and the
// per-app entry in `Settings > Privacy > <capability>`, so the result
// reflects exactly what the user will experience when WASAPI / MF try
// to open the device.
//
// Returns `true` for `Allowed`. Every other state — denied, prompt-
// required, reduced-functionality — gates the capability off because
// the recording engine cannot safely assume the device will open.
//
// We also return `true` if the WinRT API throws or returns `nullptr`
// (e.g. older Windows builds without the API). The intent is to fail
// open so a missing telemetry signal doesn't block a user who actually
// has permission. The real device activation in Phase 3D will surface
// a structured error if the access turns out to be denied.
bool ProbeCapability(winrt::hstring capability_name) {
  try {
    auto capability = cap::AppCapability::Create(capability_name);
    if (capability == nullptr) {
      return true;
    }
    return capability.CheckAccess() == cap::AppCapabilityAccessStatus::Allowed;
  } catch (winrt::hresult_error const&) {
    return true;
  }
}

}  // namespace

PermissionSnapshot ProbePermissionStatus() {
  PermissionSnapshot out;
  out.microphone = ProbeCapability(L"microphone");
  out.camera = ProbeCapability(L"webcam");
  // Screen recording + accessibility stay at their defaults (true) —
  // Windows has no per-app gate for either.
  return out;
}

std::wstring ResolveSettingsUri(const std::string& pane) {
  // Single source of truth for the pane → `ms-settings:` mapping.
  // Tests pin the table; keeping the if/else chain inline (rather
  // than a std::map) lets the test compare strings without a
  // dependency on std::map iteration order.
  if (pane == "microphone") {
    return L"ms-settings:privacy-microphone";
  }
  if (pane == "camera" || pane == "webcam") {
    return L"ms-settings:privacy-webcam";
  }
  if (pane == "screenRecording") {
    // Windows has no dedicated screen-recording page. The closest
    // analogue is the general privacy hub, which surfaces the
    // "Allow desktop apps to access your..." top-level toggles.
    return L"ms-settings:privacy";
  }
  if (pane == "accessibility") {
    return L"ms-settings:easeofaccess";
  }
  return {};
}

bool LaunchSettingsUri(const std::wstring& uri) {
  if (uri.empty()) {
    return false;
  }
  // `ShellExecuteW` returns a fake HINSTANCE; values > 32 mean success.
  // SW_SHOWNORMAL is the documented show-cmd for opening Settings.
  const HINSTANCE result = ::ShellExecuteW(/*hwnd=*/nullptr, L"open",
                                            uri.c_str(),
                                            /*params=*/nullptr,
                                            /*dir=*/nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(result) > 32;
}

}  // namespace clingfy::permissions
