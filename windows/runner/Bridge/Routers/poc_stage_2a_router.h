#ifndef RUNNER_BRIDGE_ROUTERS_POC_STAGE_2A_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_POC_STAGE_2A_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::poc_stage_2a {

// Debug-only POC methods for Phase 5 Stage 2A bridge validation.
//
// `pocStage2aStart` allocates a DXGI shared-handle D3D11 texture,
// registers it with the Flutter Windows TextureRegistrar, and returns
// the texture id + diagnostics. The Dart-side debug screen (gated by
// `const bool.fromEnvironment('POC_STAGE_2A')`) mounts a
// `Texture(textureId: ...)` widget on the returned id.
//
// `pocStage2aStop` unregisters the texture and writes
// `build/windows-poc/stage2a_result.md` with the Flutter
// SchedulerBinding timings passed from Dart.
//
// Neither method is wired into any production UI; the methods are
// present in the router only so the Flutter MissingPluginException
// path doesn't fire when the debug screen calls them.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::poc_stage_2a

#endif  // RUNNER_BRIDGE_ROUTERS_POC_STAGE_2A_ROUTER_H_
