#include "Bridge/Routers/camera_overlay_router.h"

#include <cstdint>

#include "Bridge/result_helpers.h"
#include "Capture/Camera/live_camera_texture.h"

namespace clingfy::bridge::routers::camera_overlay {

namespace {

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

// Phase 9.3.1: the Dart recording UI calls this once to get the id of the
// app-lifetime live-camera preview texture, then mounts a Texture(textureId)
// widget (shown while recording with the camera on). Returns -1 if the texture
// is unavailable (registration failed) — Dart then shows no live preview.
void HandleGetCameraPreviewTextureId(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::int64_t id =
      clingfy::capture::LiveCameraTexture::Instance().texture_id();
  reply::Map(*result, flutter::EncodableMap{
                          {flutter::EncodableValue("textureId"),
                           flutter::EncodableValue(id)},
                      });
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

  // Phase 9.3.1: live camera preview texture id (real handler).
  table["getCameraPreviewTextureId"] = &HandleGetCameraPreviewTextureId;
}

}  // namespace clingfy::bridge::routers::camera_overlay
