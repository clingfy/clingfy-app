#ifndef RUNNER_BRIDGE_ROUTERS_DEVICES_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_DEVICES_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::devices {

// Display / window / audio / video target discovery and selection.
//
// Phase 2: getters return real enumerations (Win32 EnumDisplayMonitors /
// EnumWindows, WASAPI capture endpoints, Media Foundation video capture
// sources). Setters are still no-op success — they begin storing selection
// state in Phase 3 alongside the recording engine.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::devices

#endif  // RUNNER_BRIDGE_ROUTERS_DEVICES_ROUTER_H_
