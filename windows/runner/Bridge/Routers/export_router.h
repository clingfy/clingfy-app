#ifndef RUNNER_BRIDGE_ROUTERS_EXPORT_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_EXPORT_ROUTER_H_

#include <string>

#include "Bridge/method_router.h"
#include "Capture/Export/export_passthrough.h"

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

// Complete the exportVideo MethodResult for a finished export — the single
// outcome → error-code mapping shared by the synchronous (tests / cold
// start) and worker-thread (production) paths. Exposed so unit tests can pin
// the contract per PassthroughError without staging a real disk-full /
// cancel race:
//   kNone          → Success(output_path)
//   kInputMissing  → EXPORT_INPUT_MISSING
//   kNoDestination → BAD_ARGS
//   kDiskFull      → EXPORT_DISK_FULL with the macOS-shaped details map
//                    ({stage, reason, context:{tempPath, *TempBytes,
//                    *TempFormatted}})
//   kCancelled     → EXPORT_CANCELLED, message "Export cancelled."
//   anything else  → EXPORT_ERROR (default: guard kept — a new enum value
//                    must never strand the Dart future)
// Every non-cancel failure also emits one NativeLogPublisher Error line
// (Warn for cancel); both are no-ops when no channel is attached (tests).
void ReplyForExportOutcome(
    flutter::MethodResult<flutter::EncodableValue>& result,
    const clingfy::capture::export_::PassthroughResult& outcome,
    const std::string& project_path, const std::string& directory_override);

}  // namespace clingfy::bridge::routers::export_

#endif  // RUNNER_BRIDGE_ROUTERS_EXPORT_ROUTER_H_
