#ifndef RUNNER_BRIDGE_ROUTERS_RECORDING_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_RECORDING_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::recording {

// Registers Phase 1 stub handlers for the recording-lifecycle and
// recording-settings methods: `startRecording`, `stopRecording`, pause/resume,
// `getRecordingCapabilities`, quality/template/exclusion/frame-rate setters,
// and capture diagnostics.
//
// Action methods (`startRecording`, `stopRecording`) return
// `WINDOWS_NOT_IMPLEMENTED` so the user gets a clean error if they hit Record.
// Setters are no-op success so the Flutter `RecordingSettingsController` can
// finish startup writes without flagging an error.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::recording

#endif  // RUNNER_BRIDGE_ROUTERS_RECORDING_ROUTER_H_
