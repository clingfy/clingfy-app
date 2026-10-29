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
//
// Fixed-target zoom (2026-10-29):
//   - `previewGetZoomCapabilities` reports all three capabilities true.
//   - `previewGetCursorSamples` answers from the open session's cursor
//     sidecar (empty, never an error, without one).
//   - `previewGetSourceDimensions` answers the decoded video's size, zero
//     before the first frame.
//   - `previewSetZoomSegments` carries each segment's pinned point.
void RegisterHandlers(HandlerTable& table);

}  // namespace clingfy::bridge::routers::preview

#endif  // RUNNER_BRIDGE_ROUTERS_PREVIEW_ROUTER_H_
