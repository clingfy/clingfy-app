#include "Permissions/camera_readiness.h"

#include <algorithm>

namespace clingfy::permissions {

CameraReadinessResult ResolveCameraReadiness(
    CameraPermission permission,
    const std::optional<std::string>& selected_id,
    const std::vector<std::string>& available_ids) {
  CameraReadinessResult out;

  // 1) Privacy gate first. A denied/undetermined privacy state blocks the
  //    camera regardless of how many devices are plugged in. kUnavailableApi
  //    fails open (old Windows without AppCapability) and falls through.
  switch (permission) {
    case CameraPermission::kDeniedBySystem:
      out.code = CameraReadinessCode::kPermissionDeniedSystem;
      return out;
    case CameraPermission::kDeniedByUser:
      out.code = CameraReadinessCode::kPermissionDeniedUser;
      return out;
    case CameraPermission::kNotDetermined:
      out.code = CameraReadinessCode::kPermissionNotDetermined;
      return out;
    case CameraPermission::kGranted:
    case CameraPermission::kUnavailableApi:
      break;  // privacy satisfied — continue to device checks.
  }

  // 2) Device availability.
  if (available_ids.empty()) {
    out.code = CameraReadinessCode::kNoDevicesAvailable;
    return out;
  }

  // 3) Selection.
  if (!selected_id.has_value() || selected_id->empty()) {
    out.code = CameraReadinessCode::kNoDeviceSelected;
    return out;
  }

  // 4) Does the selection still exist?
  const bool present = std::find(available_ids.begin(), available_ids.end(),
                                 *selected_id) != available_ids.end();
  if (!present) {
    out.code = CameraReadinessCode::kSelectedDeviceMissing;
    return out;
  }

  out.code = CameraReadinessCode::kReady;
  out.can_capture = true;
  return out;
}

bool ShouldAttemptCameraCapture(bool disable_camera_overlay,
                                const CameraReadinessResult& readiness) {
  // The user's explicit opt-out wins over everything. Otherwise capture only
  // when fully ready.
  if (disable_camera_overlay) {
    return false;
  }
  return readiness.can_capture;
}

const char* CameraReadinessReason(CameraReadinessCode code) {
  switch (code) {
    case CameraReadinessCode::kReady:
      return "camera ready";
    case CameraReadinessCode::kPermissionDeniedSystem:
      return "camera access is turned off in Windows privacy settings (the "
             "global camera switch or 'let desktop apps access your camera')";
    case CameraReadinessCode::kPermissionDeniedUser:
      return "camera access is turned off for this app in Windows privacy "
             "settings";
    case CameraReadinessCode::kPermissionNotDetermined:
      return "camera access has not been granted yet";
    case CameraReadinessCode::kNoDevicesAvailable:
      return "no camera devices are available";
    case CameraReadinessCode::kNoDeviceSelected:
      return "no camera device is selected";
    case CameraReadinessCode::kSelectedDeviceMissing:
      return "the selected camera is unavailable (disconnected or removed)";
  }
  return "camera unavailable";
}

}  // namespace clingfy::permissions
