#include "Bridge/Routers/camera_overlay_router.h"

#include <cstdint>

#include "Bridge/result_helpers.h"
#include "Capture/Camera/camera_overlay_geometry_store.h"
#include "Capture/Camera/camera_overlay_style_store.h"
#include "Capture/Camera/live_camera_texture.h"
#include "Capture/recording_engine.h"

namespace clingfy::bridge::routers::camera_overlay {

namespace {

const flutter::EncodableMap* ArgsMap(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

// Number readers tolerant of Dart's int/double flutter::EncodableValue variants.
double ReadDouble(const flutter::EncodableMap& map, const char* key,
                  double fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<double>(*i);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return fallback;
}

std::int64_t ReadInt(const flutter::EncodableMap& map, const char* key,
                     std::int64_t fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* i = std::get_if<std::int32_t>(&it->second)) return *i;
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) return *i64;
  if (const auto* d = std::get_if<double>(&it->second)) {
    return static_cast<std::int64_t>(*d);
  }
  return fallback;
}

bool ReadBool(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  return fallback;
}

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

// Live camera-overlay styling setters. Each writes the shared
// CameraOverlayStyleStore that the live camera compositor samples per frame so
// the recording preview reflects shape / border / shadow / opacity / mirror /
// chroma immediately (macOS parity). All reply Null — Dart treats them as
// fire-and-forget.
using clingfy::capture::CameraOverlayGeometryStore;
using clingfy::capture::CameraOverlayStyleStore;

void HandleSetShape(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetShape(
        static_cast<int>(ReadInt(*a, "shapeId", 5)));
  }
  reply::Null(*result);
}

void HandleSetRoundness(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetRoundness(
        ReadDouble(*a, "roundness", 0.0));
  }
  reply::Null(*result);
}

void HandleSetOpacity(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetOpacity(
        ReadDouble(*a, "opacity", 1.0));
  }
  reply::Null(*result);
}

void HandleSetShadow(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetShadow(
        static_cast<int>(ReadInt(*a, "shadow", 0)));
  }
  reply::Null(*result);
}

void HandleSetBorder(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetBorder(
        static_cast<int>(ReadInt(*a, "border", 0)));
  }
  reply::Null(*result);
}

void HandleSetBorderWidth(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetBorderWidth(
        ReadDouble(*a, "width", 0.0));
  }
  reply::Null(*result);
}

void HandleSetBorderColor(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetBorderColor(
        static_cast<std::uint32_t>(ReadInt(*a, "color", 0)));
  }
  reply::Null(*result);
}

void HandleSetMirror(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetMirror(
        ReadBool(*a, "mirrored", false));
  }
  reply::Null(*result);
}

void HandleSetChromaEnabled(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetChromaEnabled(
        ReadBool(*a, "enabled", false));
  }
  reply::Null(*result);
}

void HandleSetChromaStrength(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetChromaStrength(
        ReadDouble(*a, "strength", 0.4));
  }
  reply::Null(*result);
}

void HandleSetChromaColor(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayStyleStore::Instance().SetChromaColor(
        static_cast<std::uint32_t>(ReadInt(*a, "color", 0xFF00FF00)));
  }
  reply::Null(*result);
}

// Live camera-overlay geometry setters. Each writes the shared
// CameraOverlayGeometryStore that the floating overlay thread samples per tick
// so the recording bubble moves / resizes immediately (macOS parity with
// camera.resize / camera.updatePosition). All reply Null — fire-and-forget.
void HandleSetSize(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayGeometryStore::Instance().SetSize(
        ReadDouble(*a, "size", 220.0));
  }
  reply::Null(*result);
}

void HandleSetPosition(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayGeometryStore::Instance().SetPosition(
        static_cast<int>(ReadInt(*a, "position", 3)));
  }
  reply::Null(*result);
}

void HandleSetCustomPosition(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* a = ArgsMap(call)) {
    CameraOverlayGeometryStore::Instance().SetCustomPosition(
        ReadDouble(*a, "normalizedX", 0.5), ReadDouble(*a, "normalizedY", 0.5));
  }
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
  // setOverlayMirror is registered under "Shape / styling" below (real handler).

  // Camera overlay show / hide.
  table["showCameraOverlay"] = &HandleNoopSetter;
  table["hideCameraOverlay"] = &HandleNoopSetter;

  // Geometry — live floating-bubble placement (writes CameraOverlayGeometryStore,
  // applied by the floating overlay thread via SetWindowPos).
  table["setCameraOverlaySize"] = &HandleSetSize;
  table["setCameraOverlayPosition"] = &HandleSetPosition;
  table["setCameraOverlayCustomPosition"] = &HandleSetCustomPosition;
  // Absolute pixel frame (macOS setFrame): unused on Windows — the bubble is
  // placed by size + corner/normalized center, so this stays a no-op.
  table["setCameraOverlayFrame"] = &HandleNoopSetter;

  // Shape / styling — live camera bubble style (writes CameraOverlayStyleStore,
  // sampled by the live compositor for WYSIWYG parity with the export).
  table["setCameraOverlayShape"] = &HandleSetShape;
  table["setCameraOverlayRoundness"] = &HandleSetRoundness;
  table["setCameraOverlayOpacity"] = &HandleSetOpacity;
  table["setCameraOverlayShadow"] = &HandleSetShadow;
  table["setCameraOverlayBorder"] = &HandleSetBorder;
  table["setCameraOverlayBorderWidth"] = &HandleSetBorderWidth;
  table["setCameraOverlayBorderColor"] = &HandleSetBorderColor;
  table["setOverlayMirror"] = &HandleSetMirror;

  // Cursor highlight (overlay-managed, hence routed here next to the other
  // overlay setters rather than under recording).
  table["setCameraOverlayHighlight"] = &HandleNoopSetter;
  table["setCameraOverlayHighlightStrength"] = &HandleNoopSetter;
  table["setCursorHighlightEnabled"] = &HandleNoopSetter;
  table["setCursorHighlightLinkedToRecording"] = &HandleNoopSetter;

  // Chroma key — live camera bubble style (same store).
  table["setChromaKeyEnabled"] = &HandleSetChromaEnabled;
  table["setChromaKeyColor"] = &HandleSetChromaColor;
  table["setChromaKeyStrength"] = &HandleSetChromaStrength;

  // Phase 9.3.1: live camera preview texture id (real handler).
  table["getCameraPreviewTextureId"] = &HandleGetCameraPreviewTextureId;
  // Phase 9.3.2: floating vs in-app preview mode (real handler).
  table["setCameraPreviewMode"] = &HandleSetCameraPreviewMode;
}

}  // namespace clingfy::bridge::routers::camera_overlay
