#ifndef RUNNER_BRIDGE_ROUTERS_UPDATER_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_UPDATER_ROUTER_H_

#include "Bridge/method_router.h"

// Phase 10.6 — the real `checkForUpdates` (D2), moved out of misc_router's
// hardcoded-false stub. Results travel as events on
// `com.clingfy/updater/events` (UpdaterEventPublisher); the method's bool
// return only says whether a check could be STARTED, mirroring macOS where
// `checkForUpdates` replies true and Sparkle reports asynchronously.
namespace clingfy::bridge::routers::updater {

void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::updater

#endif  // RUNNER_BRIDGE_ROUTERS_UPDATER_ROUTER_H_
