#include "Permissions/permission_probe.h"

#include <gtest/gtest.h>

namespace clingfy::permissions {
namespace {

TEST(PermissionProbeTest, ResolveSettingsUriMicrophone) {
  EXPECT_EQ(ResolveSettingsUri("microphone"),
            L"ms-settings:privacy-microphone");
}

TEST(PermissionProbeTest, ResolveSettingsUriCameraAcceptsBothAliases) {
  // Dart spells the pane "camera"; the WinRT capability uses "webcam".
  // The router accepts both so future Dart additions don't have to
  // care which spelling the OS uses.
  EXPECT_EQ(ResolveSettingsUri("camera"), L"ms-settings:privacy-webcam");
  EXPECT_EQ(ResolveSettingsUri("webcam"), L"ms-settings:privacy-webcam");
}

TEST(PermissionProbeTest, ResolveSettingsUriScreenRecording) {
  // Windows has no dedicated page; the general privacy hub is the
  // closest analogue and is what we deep-link to.
  EXPECT_EQ(ResolveSettingsUri("screenRecording"), L"ms-settings:privacy");
}

TEST(PermissionProbeTest, ResolveSettingsUriAccessibility) {
  EXPECT_EQ(ResolveSettingsUri("accessibility"),
            L"ms-settings:easeofaccess");
}

TEST(PermissionProbeTest, ResolveSettingsUriUnknownReturnsEmpty) {
  EXPECT_TRUE(ResolveSettingsUri("nonsense").empty());
  EXPECT_TRUE(ResolveSettingsUri("").empty());
}

TEST(PermissionProbeTest, ProbeReturnsTrueDefaultsForScreenAndAccessibility) {
  // The mic / camera fields depend on the host's privacy settings — we
  // do not assert on them. But screen recording + accessibility are
  // hard-coded true on Windows, and that contract is what the Dart
  // preflight relies on.
  const auto snap = ProbePermissionStatus();
  EXPECT_TRUE(snap.screen_recording);
  EXPECT_TRUE(snap.accessibility);
}

TEST(PermissionProbeTest, LaunchSettingsUriRejectsEmpty) {
  EXPECT_FALSE(LaunchSettingsUri(L""));
}


TEST(PermissionProbeTest, ResolveSettingsUriSound) {
  // Phase 10.2: input/output device settings — the guidance target for
  // "system audio unavailable" / "selected mic unavailable" states.
  EXPECT_EQ(ResolveSettingsUri("sound"), L"ms-settings:sound");
}

TEST(PermissionProbeTest, ProbeMicrophonePermissionReturnsAValidBucket) {
  // Live privacy state is host-dependent; the contract under test is that
  // the detailed mic probe always lands in a defined enum bucket.
  const CameraPermission p = ProbeMicrophonePermission();
  EXPECT_TRUE(p == CameraPermission::kGranted ||
              p == CameraPermission::kDeniedBySystem ||
              p == CameraPermission::kDeniedByUser ||
              p == CameraPermission::kNotDetermined ||
              p == CameraPermission::kUnavailableApi);
}

}  // namespace
}  // namespace clingfy::permissions
