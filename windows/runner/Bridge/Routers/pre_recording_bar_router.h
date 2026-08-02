#ifndef RUNNER_BRIDGE_ROUTERS_PRE_RECORDING_BAR_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_PRE_RECORDING_BAR_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::pre_recording_bar {

// The floating pre-recording control bar (Slice 4): setPreRecordingBarEnabled /
// setPreRecordingBarVisible / showPreRecordingBar / togglePreRecordingBar /
// setPreRecordingBarState. Parses the Dart state feed + lifecycle calls and
// drives the Win32 `PreRecordingBarController` overlay. The button taps
// (reverse `preRecordingBarAction`) land in Slice 5; the native pickers in
// Slice 6. Every handler replies null (the void Dart contract).
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::pre_recording_bar

#endif  // RUNNER_BRIDGE_ROUTERS_PRE_RECORDING_BAR_ROUTER_H_
