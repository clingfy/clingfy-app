#ifndef RUNNER_BRIDGE_ROUTERS_INDICATOR_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_INDICATOR_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::indicator {

// Recording-indicator pinning and the pre-recording bar.
//
// Phase 1: both surfaces are no-op success. The pre-recording bar is a
// macOS-only floating panel; Windows will get a Win32 equivalent in Phase 10
// alongside the recording indicator window.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::indicator

#endif  // RUNNER_BRIDGE_ROUTERS_INDICATOR_ROUTER_H_
