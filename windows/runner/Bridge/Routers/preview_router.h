#ifndef RUNNER_BRIDGE_ROUTERS_PREVIEW_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_PREVIEW_ROUTER_H_

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::preview {

// Preview / player / zoom-timeline methods.
//
// Phase 1:
//   - Lifecycle and transport setters (`previewOpen`, `previewClose`,
//     `previewPlay`, `previewPause`, `previewSeekTo`, `previewPeekTo`,
//     `playerPlay`, `playerPause`, `playerSeekTo`, `inlinePreviewStop`) are
//     no-op success. There is no native preview engine on Windows yet, but
//     the Flutter post-processing UI fires these to "warm up" preview state.
//   - `previewSetCameraPlacement`, `previewSetZoomSegments`,
//     `previewSetAudioMix` are no-op success for the same reason.
//   - `previewGetZoomCapabilities` reports `{cursorSamples:false,
//     fixedTargetPreview:false, fixedTargetExport:false}` so the Dart side
//     hides the smart fixed-target UX.
//   - `previewGetCursorSamples` returns an empty samples response so the
//     fallback path takes over.
//   - `previewGetSourceDimensions` returns null.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::preview

#endif  // RUNNER_BRIDGE_ROUTERS_PREVIEW_ROUTER_H_
