#include "Bridge/Routers/preview_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::preview {

namespace {

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

// `previewGetZoomCapabilities` gates the Phase 1 smart-fixed-target zoom UX
// on the Dart side. Reporting `false` for every capability is the
// documented way to keep the legacy follow-cursor experience and avoid
// surfacing UI that has no native backing yet.
void HandleGetZoomCapabilities(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap value{
      {flutter::EncodableValue("cursorSamples"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("fixedTargetPreview"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("fixedTargetExport"),
       flutter::EncodableValue(false)},
  };
  reply::Map(*result, std::move(value));
}

// Empty cursor-samples response. Shape matches `CursorSamplesResult.fromMap`:
// an empty `samples` list and zero width/height. `playheadSample` is omitted
// (the Dart parser tolerates the absence). The "samples not available"
// signal is communicated via the Phase 1 zoom-capabilities probe above;
// returning a structured empty payload here keeps any rogue call from
// failing.
void HandleGetCursorSamples(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap value{
      {flutter::EncodableValue("samples"),
       flutter::EncodableValue(flutter::EncodableList{})},
      {flutter::EncodableValue("width"), flutter::EncodableValue(0.0)},
      {flutter::EncodableValue("height"), flutter::EncodableValue(0.0)},
  };
  reply::Map(*result, std::move(value));
}

// `previewGetSourceDimensions` returns null when no preview is active. Dart
// hides hit-testing UI when this is null, which is exactly the Phase 1
// behavior we want.
void HandleGetSourceDimensions(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["previewOpen"] = &HandleNoopSetter;
  table["previewClose"] = &HandleNoopSetter;
  table["previewPlay"] = &HandleNoopSetter;
  table["previewPause"] = &HandleNoopSetter;
  table["previewSeekTo"] = &HandleNoopSetter;
  table["previewPeekTo"] = &HandleNoopSetter;

  table["playerPlay"] = &HandleNoopSetter;
  table["playerPause"] = &HandleNoopSetter;
  table["playerSeekTo"] = &HandleNoopSetter;
  table["inlinePreviewStop"] = &HandleNoopSetter;

  table["previewSetCameraPlacement"] = &HandleNoopSetter;
  table["previewSetZoomSegments"] = &HandleNoopSetter;
  table["previewSetAudioMix"] = &HandleNoopSetter;
  table["previewSetAudioGainDb"] = &HandleNoopSetter;

  table["previewGetZoomCapabilities"] = &HandleGetZoomCapabilities;
  table["previewGetCursorSamples"] = &HandleGetCursorSamples;
  table["previewGetSourceDimensions"] = &HandleGetSourceDimensions;
}

}  // namespace clingfy::bridge::routers::preview
