#ifndef RUNNER_BRIDGE_ROUTERS_INDICATOR_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_INDICATOR_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::indicator {

// Recording-indicator pinning (setRecordingIndicatorPinned) plus the runtime
// native-log-level + flush handshakes. The pre-recording bar moved to
// `routers::pre_recording_bar` in Slice 4.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::indicator

#endif  // RUNNER_BRIDGE_ROUTERS_INDICATOR_ROUTER_H_
