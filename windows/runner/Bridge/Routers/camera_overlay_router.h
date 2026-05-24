#ifndef RUNNER_BRIDGE_ROUTERS_CAMERA_OVERLAY_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_CAMERA_OVERLAY_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::camera_overlay {

// Camera-overlay visibility, geometry, shape, border, shadow, chroma key, and
// cursor highlight setters.
//
// Phase 1: all no-op success. The overlay does not render on Windows yet, but
// the Flutter UI builds a long stream of `setCameraOverlay*` calls at startup
// from the persisted preferences -- silently accepting them keeps the UI from
// surfacing a wall of errors.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::camera_overlay

#endif  // RUNNER_BRIDGE_ROUTERS_CAMERA_OVERLAY_ROUTER_H_
