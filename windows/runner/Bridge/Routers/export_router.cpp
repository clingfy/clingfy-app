#include "Bridge/Routers/export_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::export_ {

namespace {

void HandleNotImplemented(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::NotImplemented(*result, call.method_name());
}

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

void HandleEmptyList(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::EmptyList(*result);
}

void HandleSaveManualZoomSegments(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Dart treats `false` as "save failed"; the manual-zoom workflow falls
  // back gracefully. Real persistence lands once Phase 6 wires up the
  // project-bundle writer.
  reply::Bool(*result, false);
}

// `RecordingSceneInfo.fromMap` requires at least `projectPath`; falling back
// on the caller's path keeps the post-processing screen from crashing if it
// ever reaches a state where this is invoked.
void HandleGetRecordingSceneInfo(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string project_path;
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    auto it = args->find(flutter::EncodableValue("projectPath"));
    if (it != args->end()) {
      if (const auto* value = std::get_if<std::string>(&it->second)) {
        project_path = *value;
      }
    }
  }

  flutter::EncodableMap value{
      {flutter::EncodableValue("projectPath"),
       flutter::EncodableValue(project_path)},
      {flutter::EncodableValue("screenPath"),
       flutter::EncodableValue(project_path)},
  };
  reply::Map(*result, std::move(value));
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["exportVideo"] = &HandleNotImplemented;
  table["processVideo"] = &HandleNotImplemented;
  table["cancelExport"] = &HandleNoopSetter;

  table["getRecordingSceneInfo"] = &HandleGetRecordingSceneInfo;

  table["getZoomSegments"] = &HandleEmptyList;
  table["getManualZoomSegments"] = &HandleEmptyList;
  table["saveManualZoomSegments"] = &HandleSaveManualZoomSegments;
}

}  // namespace clingfy::bridge::routers::export_
