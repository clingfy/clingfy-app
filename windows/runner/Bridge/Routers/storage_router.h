#ifndef RUNNER_BRIDGE_ROUTERS_STORAGE_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_STORAGE_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::storage {

// Save folder, log/recording reveal helpers, storage snapshot, cached
// recordings cleanup.
//
// Phase 1:
//   - `getSaveFolder` and `getTodayLogFilePath` return null.
//   - `chooseSaveFolder` returns null (treated as "user cancelled" by Dart).
//   - `resetSaveFolder`, `openSaveFolder`, all `reveal*` helpers are no-op
//     success. ShellExecute wiring lands in Phase 10 polish.
//   - `clearCachedRecordings` returns `{deletedCount: 0}`.
//   - `getStorageSnapshot` returns a zero-filled snapshot so the storage
//     dashboard renders without crashing. Real values arrive in Phase 10.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::storage

#endif  // RUNNER_BRIDGE_ROUTERS_STORAGE_ROUTER_H_
