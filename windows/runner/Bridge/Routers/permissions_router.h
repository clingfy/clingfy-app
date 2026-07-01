#ifndef RUNNER_BRIDGE_ROUTERS_PERMISSIONS_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_PERMISSIONS_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::permissions {

// Permission status / request methods, plus the "open <X> settings" shortcuts
// and `relaunchApp`.
//
// Phase 1:
//   - `getPermissionStatus` returns an empty map. The Dart parser treats
//     missing keys as `false`, so the onboarding screen surfaces "permission
//     not granted" for everything until Phase 10 wires up
//     CapabilityAccessManager.
//   - `requestScreenRecordingPermission` / `requestMicrophonePermission` /
//     `requestCameraPermission` return `false`.
//   - `isAccessibilityTrusted` returns `false`.
//   - `openAccessibilitySettings`, `openScreenRecordingSettings`,
//     `openSystemSettings` and `relaunchApp` are no-op success.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::permissions

#endif  // RUNNER_BRIDGE_ROUTERS_PERMISSIONS_ROUTER_H_
