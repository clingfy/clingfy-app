#include "Permissions/camera_readiness.h"

#include <gtest/gtest.h>

#include <optional>
#include <string>
#include <vector>

namespace clingfy::permissions {
namespace {

const std::vector<std::string> kTwoCameras = {"\\\\?\\usb#vid_046d&pid_0825",
                                              "\\\\?\\usb#vid_1bcf&pid_2284"};

// ---- Privacy gate takes precedence over device state -----------------------

TEST(CameraReadinessTest, SystemDeniedBlocksEvenWithSelectedDevice) {
  const auto r = ResolveCameraReadiness(CameraPermission::kDeniedBySystem,
                                        kTwoCameras.front(), kTwoCameras);
  EXPECT_EQ(r.code, CameraReadinessCode::kPermissionDeniedSystem);
  EXPECT_FALSE(r.can_capture);
}

TEST(CameraReadinessTest, UserDeniedBlocksEvenWithSelectedDevice) {
  const auto r = ResolveCameraReadiness(CameraPermission::kDeniedByUser,
                                        kTwoCameras.front(), kTwoCameras);
  EXPECT_EQ(r.code, CameraReadinessCode::kPermissionDeniedUser);
  EXPECT_FALSE(r.can_capture);
}

TEST(CameraReadinessTest, NotDeterminedBlocksEvenWithSelectedDevice) {
  const auto r = ResolveCameraReadiness(CameraPermission::kNotDetermined,
                                        kTwoCameras.front(), kTwoCameras);
  EXPECT_EQ(r.code, CameraReadinessCode::kPermissionNotDetermined);
  EXPECT_FALSE(r.can_capture);
}

// ---- Device availability (privacy satisfied) -------------------------------

TEST(CameraReadinessTest, GrantedButNoDevicesAvailable) {
  const auto r = ResolveCameraReadiness(CameraPermission::kGranted,
                                        std::nullopt, /*available=*/{});
  EXPECT_EQ(r.code, CameraReadinessCode::kNoDevicesAvailable);
  EXPECT_FALSE(r.can_capture);
}

TEST(CameraReadinessTest, GrantedDevicesPresentButNoneSelected) {
  const auto r = ResolveCameraReadiness(CameraPermission::kGranted,
                                        std::nullopt, kTwoCameras);
  EXPECT_EQ(r.code, CameraReadinessCode::kNoDeviceSelected);
  EXPECT_FALSE(r.can_capture);
}

TEST(CameraReadinessTest, EmptySelectedIdTreatedAsNoSelection) {
  // ReadOptionalString maps "" → nullopt, but guard the resolver too.
  const auto r = ResolveCameraReadiness(CameraPermission::kGranted,
                                        std::string(""), kTwoCameras);
  EXPECT_EQ(r.code, CameraReadinessCode::kNoDeviceSelected);
  EXPECT_FALSE(r.can_capture);
}

TEST(CameraReadinessTest, SelectedDeviceMissingFromLiveList) {
  const auto r = ResolveCameraReadiness(
      CameraPermission::kGranted,
      std::string("\\\\?\\usb#vid_dead&pid_beef"), kTwoCameras);
  EXPECT_EQ(r.code, CameraReadinessCode::kSelectedDeviceMissing);
  EXPECT_FALSE(r.can_capture);
}

TEST(CameraReadinessTest, GrantedWithSelectedPresentDeviceIsReady) {
  const auto r = ResolveCameraReadiness(CameraPermission::kGranted,
                                        kTwoCameras.back(), kTwoCameras);
  EXPECT_EQ(r.code, CameraReadinessCode::kReady);
  EXPECT_TRUE(r.can_capture);
}

// Fail-open: a host without the AppCapability API is treated as
// privacy-satisfied and falls through to the normal device checks.
TEST(CameraReadinessTest, UnavailableApiFallsThroughToDeviceChecks) {
  const auto ready = ResolveCameraReadiness(
      CameraPermission::kUnavailableApi, kTwoCameras.front(), kTwoCameras);
  EXPECT_EQ(ready.code, CameraReadinessCode::kReady);
  EXPECT_TRUE(ready.can_capture);

  const auto missing = ResolveCameraReadiness(
      CameraPermission::kUnavailableApi, std::nullopt, kTwoCameras);
  EXPECT_EQ(missing.code, CameraReadinessCode::kNoDeviceSelected);
}

// ---- The capture gate ------------------------------------------------------

TEST(CameraReadinessTest, DisableFlagOverridesAReadyCamera) {
  const auto ready = ResolveCameraReadiness(CameraPermission::kGranted,
                                            kTwoCameras.front(), kTwoCameras);
  EXPECT_TRUE(ShouldAttemptCameraCapture(/*disable=*/false, ready));
  EXPECT_FALSE(ShouldAttemptCameraCapture(/*disable=*/true, ready));
}

TEST(CameraReadinessTest, NotReadyNeverCapturesEvenWhenEnabled) {
  const auto denied = ResolveCameraReadiness(CameraPermission::kDeniedByUser,
                                             kTwoCameras.front(), kTwoCameras);
  EXPECT_FALSE(ShouldAttemptCameraCapture(/*disable=*/false, denied));
  EXPECT_FALSE(ShouldAttemptCameraCapture(/*disable=*/true, denied));
}

// ---- Reason strings (surfacing) --------------------------------------------

TEST(CameraReadinessTest, EveryCodeHasANonEmptyDistinctReason) {
  const CameraReadinessCode codes[] = {
      CameraReadinessCode::kReady,
      CameraReadinessCode::kPermissionDeniedSystem,
      CameraReadinessCode::kPermissionDeniedUser,
      CameraReadinessCode::kPermissionNotDetermined,
      CameraReadinessCode::kNoDevicesAvailable,
      CameraReadinessCode::kNoDeviceSelected,
      CameraReadinessCode::kSelectedDeviceMissing,
  };
  std::vector<std::string> seen;
  for (const auto code : codes) {
    const std::string reason = CameraReadinessReason(code);
    EXPECT_FALSE(reason.empty());
    for (const auto& prev : seen) {
      EXPECT_NE(prev, reason) << "duplicate reason: " << reason;
    }
    seen.push_back(reason);
  }
}


TEST(CameraReadinessTest, WireNamesAreStableAndUnique) {
  // Phase 10.2: these strings ARE the getWindowsPermissionDetails wire
  // contract with lib/core/permissions/models/windows_permission_details.dart
  // — renaming one silently breaks Dart's state mapping.
  EXPECT_STREQ(CameraReadinessCodeName(CameraReadinessCode::kReady), "ready");
  EXPECT_STREQ(
      CameraReadinessCodeName(CameraReadinessCode::kPermissionDeniedSystem),
      "permissionDeniedSystem");
  EXPECT_STREQ(
      CameraReadinessCodeName(CameraReadinessCode::kPermissionDeniedUser),
      "permissionDeniedUser");
  EXPECT_STREQ(
      CameraReadinessCodeName(CameraReadinessCode::kPermissionNotDetermined),
      "permissionNotDetermined");
  EXPECT_STREQ(
      CameraReadinessCodeName(CameraReadinessCode::kNoDevicesAvailable),
      "noDevicesAvailable");
  EXPECT_STREQ(CameraReadinessCodeName(CameraReadinessCode::kNoDeviceSelected),
               "noDeviceSelected");
  EXPECT_STREQ(
      CameraReadinessCodeName(CameraReadinessCode::kSelectedDeviceMissing),
      "selectedDeviceMissing");

  EXPECT_STREQ(CameraPermissionName(CameraPermission::kGranted), "granted");
  EXPECT_STREQ(CameraPermissionName(CameraPermission::kDeniedBySystem),
               "deniedBySystem");
  EXPECT_STREQ(CameraPermissionName(CameraPermission::kDeniedByUser),
               "deniedByUser");
  EXPECT_STREQ(CameraPermissionName(CameraPermission::kNotDetermined),
               "notDetermined");
  EXPECT_STREQ(CameraPermissionName(CameraPermission::kUnavailableApi),
               "unavailableApi");
}

}  // namespace
}  // namespace clingfy::permissions
