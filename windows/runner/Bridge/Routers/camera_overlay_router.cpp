#include "Bridge/Routers/camera_overlay_router.h"

#include <cstdint>

#include "Bridge/result_helpers.h"
#include "Capture/Camera/live_camera_texture.h"
#include "Capture/recording_engine.h"

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

// Phase 9.3.2: select the live camera preview mode for the current recording.
// Dart sends {floating: bool}; the engine shows the floating bubble only if it
// exists AND capture-exclusion succeeded. Replies {floating: <resulting>} —
// false means Dart should use the in-app texture (floating requested but
// unavailable, or in-app requested).
void HandleSetCameraPreviewMode(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  bool floating = false;
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    const auto it = args->find(flutter::EncodableValue("floating"));
    if (it != args->end()) {
      if (const auto* b = std::get_if<bool>(&it->second)) {
        floating = *b;
      }
    }
  }
  const bool resulting =
      clingfy::capture::RecordingEngine::Instance().SetCameraPreviewFloating(
          floating);
  reply::Map(*result, flutter::EncodableMap{
                          {flutter::EncodableValue("floating"),
                           flutter::EncodableValue(resulting)},
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
  // Phase 9.3.2: floating vs in-app preview mode (real handler).
  table["setCameraPreviewMode"] = &HandleSetCameraPreviewMode;
}

}  // namespace clingfy::bridge::routers::camera_overlay
