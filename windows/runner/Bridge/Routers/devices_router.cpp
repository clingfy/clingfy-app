#include "Bridge/Routers/devices_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::devices {

namespace {

void HandleEmptyList(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::EmptyList(*result);
}

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  // Discovery -- empty list until Phase 2 wires up real enumeration.
  table["getDisplays"] = &HandleEmptyList;
  table["getAppWindows"] = &HandleEmptyList;
  table["getAudioSources"] = &HandleEmptyList;
  table["getVideoSources"] = &HandleEmptyList;

  // Selection -- no-op success.
  table["setDisplay"] = &HandleNoopSetter;
  table["setAppWindowTarget"] = &HandleNoopSetter;
  table["setDisplayTargetMode"] = &HandleNoopSetter;
  table["setAudioSource"] = &HandleNoopSetter;
  table["setVideoSource"] = &HandleNoopSetter;

  // Audio gain / mix -- accepted, no audible effect until Phase 3.
  table["updateAudioPreview"] = &HandleNoopSetter;
  table["setAudioMix"] = &HandleNoopSetter;
  table["setAudioGainDb"] = &HandleNoopSetter;

  // Area selection lifecycle -- no overlay UI yet, accept and succeed so the
  // Dart flow that toggles area-mode doesn't surface an error.
  table["pickAreaRecordingRegion"] = &HandleNoopSetter;
  table["revealAreaRecordingRegion"] = &HandleNoopSetter;
  table["clearAreaRecordingSelection"] = &HandleNoopSetter;
}

}  // namespace clingfy::bridge::routers::devices
