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

namespace {

// Shared detailed mapper for any AppCapability name — the buckets are
// capability-agnostic (see the header note on the enum's camera-era name).
CameraPermission ProbeCapabilityDetailed(winrt::hstring capability_name) {
  try {
    auto capability = cap::AppCapability::Create(capability_name);
    if (capability == nullptr) {
      // No AppCapability API (very old Windows) — fail open. The real device
      // activation will surface a structured error if it turns out the
      // device cannot actually be opened.
      return CameraPermission::kUnavailableApi;
    }
    switch (capability.CheckAccess()) {
      case cap::AppCapabilityAccessStatus::Allowed:
        return CameraPermission::kGranted;
      case cap::AppCapabilityAccessStatus::DeniedByUser:
        return CameraPermission::kDeniedByUser;
      case cap::AppCapabilityAccessStatus::UserPromptRequired:
        return CameraPermission::kNotDetermined;
      case cap::AppCapabilityAccessStatus::DeniedBySystem:
      // `NotDeclaredByApp` only applies to packaged apps with a missing
      // manifest capability; for our non-packaged Win32 build it is a
      // system-level denial in practice, so bucket it with DeniedBySystem.
      default:
        return CameraPermission::kDeniedBySystem;
    }
  } catch (winrt::hresult_error const&) {
    return CameraPermission::kUnavailableApi;
  }
}

}  // namespace

CameraPermission ProbeCameraPermission() {
  return ProbeCapabilityDetailed(L"webcam");
}

CameraPermission ProbeMicrophonePermission() {
  return ProbeCapabilityDetailed(L"microphone");
}

PermissionSnapshot ProbePermissionStatus() {
  PermissionSnapshot out;
  out.microphone = ProbeCapability(L"microphone");
  // The camera bool is the granted/not-granted reduction of the detailed
  // probe, so the existing bridge contract (getPermissionStatus.camera: bool)
  // stays byte-for-byte identical while the richer status is available to the
  // readiness check.
  out.camera = ProbeCameraPermission() == CameraPermission::kGranted;
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
  if (pane == "sound") {
    // Input/output device settings — Phase 10.2 guidance target for
    // "system audio unavailable" / "selected mic unavailable" states.
    return L"ms-settings:sound";
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
  if (pane == "storage") {
    // Phase 10.4: target of the RECORDING_DISK_FULL toast action. Storage
    // Sense is the canonical free-up-space page.
    return L"ms-settings:storagesense";
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
