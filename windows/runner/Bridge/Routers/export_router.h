#ifndef RUNNER_BRIDGE_ROUTERS_EXPORT_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_EXPORT_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::export_ {

// Export / processVideo / cancelExport plus the project-side queries
// (`getRecordingSceneInfo`, `getZoomSegments`, `getManualZoomSegments`,
// `saveManualZoomSegments`).
//
// Phase 1: `exportVideo` and `processVideo` return WINDOWS_NOT_IMPLEMENTED so
// the export progress dock shows a clean error. `cancelExport` is a no-op
// success. The zoom-segment queries return empty lists and the save call
// returns `false`; Dart already treats these as the "no zoom data yet"
// fallback.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::export_

#endif  // RUNNER_BRIDGE_ROUTERS_EXPORT_ROUTER_H_
