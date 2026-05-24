#ifndef RUNNER_BRIDGE_ROUTERS_MISC_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_MISC_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::misc {

// `pickImage`, `cacheLocalizedStrings`, `checkForUpdates`.
//
// Phase 1:
//   - `pickImage` returns null (treated as "user cancelled" by Dart). A real
//     IFileDialog implementation lands in Phase 6 alongside background-image
//     export support.
//   - `cacheLocalizedStrings` is no-op success. Native code does not need the
//     localized strings until it draws UI of its own.
//   - `checkForUpdates` returns `false`. WinSparkle wires in during Phase 10.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::misc

#endif  // RUNNER_BRIDGE_ROUTERS_MISC_ROUTER_H_
