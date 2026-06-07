#ifndef RUNNER_PERMISSIONS_CAMERA_READINESS_H_
#define RUNNER_PERMISSIONS_CAMERA_READINESS_H_

#include <optional>
#include <string>
#include <vector>

// Phase 9.1 — pure camera readiness logic.
//
// "Can we actually record a camera overlay right now?" is the product of two
// independent signals:
//
//   1. The Windows camera *privacy* state (a WinRT AppCapabilityAccess status).
//   2. Whether the user's selected device still exists in the live enumeration.
//
// This header keeps both as plain enums + a pure resolver so the decision is
// unit-testable without WinRT or a real camera. The WinRT probe that produces
// the `CameraPermission` value lives in `permission_probe.cpp` (it is the only
// part that needs the OS); everything here is data-in / data-out.
//
// IMPORTANT honesty note on the privacy buckets: Windows exposes two relevant
// camera privacy toggles — the global "Camera access" master switch and the
// "Let desktop apps access your camera" switch. The WinRT
// `AppCapabilityAccessStatus` API collapses *both* of those into a single
// `DeniedBySystem` value; it does not let us tell which one is off. So we report
// the two as one `kDeniedBySystem` bucket (vs. a per-app `kDeniedByUser`
// denial) and the UI/deep-link points the user at the privacy page where both
// toggles live. The third case the product wants surfaced — "the selected
// camera is unavailable" — IS precisely detectable, and is a readiness code
// here (`kSelectedDeviceMissing`), independent of the privacy buckets.
namespace clingfy::permissions {

// Windows camera privacy state, mapped from `AppCapabilityAccessStatus`.
enum class CameraPermission {
  kGranted,          // AppCapabilityAccessStatus::Allowed
  kDeniedBySystem,   // global "Camera access" OR "desktop apps" toggle off
                     //   (WinRT cannot distinguish the two)
  kDeniedByUser,     // this app's per-app camera toggle is off
  kNotDetermined,    // a prompt is required / not yet decided
  kUnavailableApi,   // the AppCapability API is missing (very old Windows);
                     //   we fail open and treat the privacy gate as satisfied
};

// The resolved "can we use the camera" verdict.
enum class CameraReadinessCode {
  kReady,                   // permission ok + a selected device that exists
  kPermissionDeniedSystem,  // privacy denied at the system/global level
  kPermissionDeniedUser,    // privacy denied for this app specifically
  kPermissionNotDetermined, // privacy not yet granted (prompt required)
  kNoDevicesAvailable,      // permission ok but no cameras are enumerated
  kNoDeviceSelected,        // permission ok, devices exist, none chosen
  kSelectedDeviceMissing,   // permission ok, but the chosen id is gone
};

struct CameraReadinessResult {
  CameraReadinessCode code = CameraReadinessCode::kNoDeviceSelected;
  // True only for kReady — the single gate the engine checks before it tries
  // to open the camera. Every non-ready code keeps this false so a caller can
  // branch on the bool and log the specific `code` for diagnostics.
  bool can_capture = false;
};

// Pure resolver. Precedence: privacy first (a denied/undetermined gate blocks
// everything regardless of devices), then device availability, then selection,
// then existence of the selection in the live list. `kUnavailableApi` is
// treated as "privacy satisfied" (fail-open) and falls through to the device
// checks. `available_ids` is the set of Media Foundation symbolic-link ids from
// the live enumerator; `selected_id` is what WindowsSelectionState holds.
CameraReadinessResult ResolveCameraReadiness(
    CameraPermission permission,
    const std::optional<std::string>& selected_id,
    const std::vector<std::string>& available_ids);

// Should the recording engine actually attempt camera capture? Combines the
// Dart `disableCameraOverlay` request flag (which wins — the user opted out)
// with the resolved readiness. Pure + tested so Phase 9.2 can call it from the
// engine without re-deriving the precedence.
bool ShouldAttemptCameraCapture(bool disable_camera_overlay,
                                const CameraReadinessResult& readiness);

// Human-readable, log-friendly reason for a readiness code (ASCII, no
// trailing punctuation). Used to surface *why* the camera is unavailable.
const char* CameraReadinessReason(CameraReadinessCode code);

}  // namespace clingfy::permissions

#endif  // RUNNER_PERMISSIONS_CAMERA_READINESS_H_
