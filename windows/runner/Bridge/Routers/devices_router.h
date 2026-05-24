#ifndef RUNNER_BRIDGE_ROUTERS_DEVICES_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_DEVICES_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::devices {

// Display / window / audio / video target discovery and selection.
//
// Phase 1: every getter returns an empty list, every setter is no-op success.
// Real enumeration lands in Phase 2 (WinRT DisplayInformation /
// Windows.Graphics.Capture / WASAPI / MediaCapture).
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::devices

#endif  // RUNNER_BRIDGE_ROUTERS_DEVICES_ROUTER_H_
