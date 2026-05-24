#include "Bridge/Routers/devices_router.h"

#include "Bridge/Devices/audio_source_enumerator.h"
#include "Bridge/Devices/device_record.h"
#include "Bridge/Devices/display_enumerator.h"
#include "Bridge/Devices/video_source_enumerator.h"
#include "Bridge/Devices/window_enumerator.h"
#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::devices {

namespace {

template <typename Record>
flutter::EncodableList Encode(const std::vector<Record>& records) {
  flutter::EncodableList list;
  list.reserve(records.size());
  for (const auto& record : records) {
    list.emplace_back(
        flutter::EncodableValue(clingfy::bridge::devices::ToEncodable(record)));
  }
  return list;
}

void HandleGetDisplays(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::List(*result,
              Encode(clingfy::bridge::devices::EnumerateDisplays()));
}

void HandleGetAppWindows(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::List(*result,
              Encode(clingfy::bridge::devices::EnumerateAppWindows()));
}

void HandleGetAudioSources(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::List(*result,
              Encode(clingfy::bridge::devices::EnumerateAudioInputs()));
}

void HandleGetVideoSources(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::List(*result,
              Encode(clingfy::bridge::devices::EnumerateVideoInputs()));
}

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  // Discovery — real enumeration in Phase 2.
  table["getDisplays"] = &HandleGetDisplays;
  table["getAppWindows"] = &HandleGetAppWindows;
  table["getAudioSources"] = &HandleGetAudioSources;
  table["getVideoSources"] = &HandleGetVideoSources;

  // Selection — still no-op success. Storing the selected target lives
  // alongside the recording engine in Phase 3, where the value actually
  // matters; for Phase 2 we keep the bridge contract intact so the Dart
  // picker can round-trip a selection without surfacing an error.
  table["setDisplay"] = &HandleNoopSetter;
  table["setAppWindowTarget"] = &HandleNoopSetter;
  table["setDisplayTargetMode"] = &HandleNoopSetter;
  table["setAudioSource"] = &HandleNoopSetter;
  table["setVideoSource"] = &HandleNoopSetter;

  // Audio gain / mix — accepted, no audible effect until Phase 3.
  table["updateAudioPreview"] = &HandleNoopSetter;
  table["setAudioMix"] = &HandleNoopSetter;
  table["setAudioGainDb"] = &HandleNoopSetter;

  // Area selection lifecycle — no overlay UI yet, accept and succeed so the
  // Dart flow that toggles area-mode does not surface an error.
  table["pickAreaRecordingRegion"] = &HandleNoopSetter;
  table["revealAreaRecordingRegion"] = &HandleNoopSetter;
  table["clearAreaRecordingSelection"] = &HandleNoopSetter;
}

}  // namespace clingfy::bridge::routers::devices
