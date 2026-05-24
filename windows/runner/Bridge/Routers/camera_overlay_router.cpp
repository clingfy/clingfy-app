#include "Bridge/Routers/camera_overlay_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::camera_overlay {

namespace {

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  // Overlay master switches.
  table["setOverlayEnabled"] = &HandleNoopSetter;
  table["setOverlayLinkedToRecording"] = &HandleNoopSetter;
  table["setOverlayMirror"] = &HandleNoopSetter;

  // Camera overlay show / hide.
  table["showCameraOverlay"] = &HandleNoopSetter;
  table["hideCameraOverlay"] = &HandleNoopSetter;

  // Geometry.
  table["setCameraOverlaySize"] = &HandleNoopSetter;
  table["setCameraOverlayFrame"] = &HandleNoopSetter;
  table["setCameraOverlayPosition"] = &HandleNoopSetter;
  table["setCameraOverlayCustomPosition"] = &HandleNoopSetter;

  // Shape / styling.
  table["setCameraOverlayShape"] = &HandleNoopSetter;
  table["setCameraOverlayRoundness"] = &HandleNoopSetter;
  table["setCameraOverlayOpacity"] = &HandleNoopSetter;
  table["setCameraOverlayShadow"] = &HandleNoopSetter;
  table["setCameraOverlayBorder"] = &HandleNoopSetter;
  table["setCameraOverlayBorderWidth"] = &HandleNoopSetter;
  table["setCameraOverlayBorderColor"] = &HandleNoopSetter;

  // Cursor highlight (overlay-managed, hence routed here next to the other
  // overlay setters rather than under recording).
  table["setCameraOverlayHighlight"] = &HandleNoopSetter;
  table["setCameraOverlayHighlightStrength"] = &HandleNoopSetter;
  table["setCursorHighlightEnabled"] = &HandleNoopSetter;
  table["setCursorHighlightLinkedToRecording"] = &HandleNoopSetter;

  // Chroma key.
  table["setChromaKeyEnabled"] = &HandleNoopSetter;
  table["setChromaKeyColor"] = &HandleNoopSetter;
  table["setChromaKeyStrength"] = &HandleNoopSetter;
}

}  // namespace clingfy::bridge::routers::camera_overlay
