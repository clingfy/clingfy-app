#include "Bridge/Routers/export_router.h"

#include <optional>
#include <string>

#include "Bridge/native_error_codes.h"
#include "Bridge/result_helpers.h"
#include "Capture/Export/export_passthrough.h"

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

// ---- Phase 6 / Slice 1 + 2 --------------------------------------------------
// `exportVideo` and `processVideo` are off the NotImplemented stub.
//   - exportVideo: writes to a Dart-chosen destination directory + filename,
//     forcing a `.mov` extension. layout=auto & resolution=auto take the
//     Slice 1 byte-for-byte copy fast-path; any other layout/resolution/fit
//     routes through the Slice 2 decode → composite → re-encode pipeline
//     (`export_pipeline.h`), carrying the source audio through. No progress
//     event yet (cancel + progress land in Slice 5).
//   - processVideo: returns null (signals "no preview file was generated;
//     re-use the original screen.mov"). Future slices will wire processVideo
//     to update the live PreviewCompositor's parameters.

const flutter::EncodableMap* AsMap(
    const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableMap>(arguments);
}

std::string ReadString(const flutter::EncodableMap& map,
                       const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return {};
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return {};
}

void HandleExportVideo(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  clingfy::capture::export_::PassthroughInput input;
  if (const auto* args = AsMap(call.arguments())) {
    input.project_path = ReadString(*args, "projectPath");
    input.directory_override = ReadString(*args, "directoryOverride");
    input.filename = ReadString(*args, "filename");
    input.format = ReadString(*args, "format");
    // Slice 2 composition args. Absent/auto leaves the export on the copy
    // fast-path; concrete values route through the re-encode pipeline.
    input.layout = ReadString(*args, "layoutPreset");
    input.resolution = ReadString(*args, "resolutionPreset");
    input.fit = ReadString(*args, "fitMode");
  }

  const auto outcome =
      clingfy::capture::export_::ExportPassthroughCopy(input);
  switch (outcome.error) {
    case clingfy::capture::export_::PassthroughError::kNone:
      reply::String(*result, outcome.output_path);
      return;
    case clingfy::capture::export_::PassthroughError::kInputMissing:
      result->Error(error::kExportInputMissing, outcome.message,
                    flutter::EncodableValue(input.project_path));
      return;
    case clingfy::capture::export_::PassthroughError::kNoDestination:
      result->Error(error::kBadArgs, outcome.message,
                    flutter::EncodableValue(input.directory_override));
      return;
    case clingfy::capture::export_::PassthroughError::kCopyFailed:
      result->Error(error::kExportError, outcome.message,
                    flutter::EncodableValue(input.project_path));
      return;
  }
}

void HandleProcessVideo(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Slice 1: return null so the Dart caller falls back to using the
  // original screen.mov as the preview source (its current behavior on
  // Windows anyway). Slices 2+ extend the PreviewCompositor with
  // composition params and start updating the live preview here.
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["exportVideo"] = &HandleExportVideo;
  table["processVideo"] = &HandleProcessVideo;
  table["cancelExport"] = &HandleNoopSetter;

  // `getRecordingSceneInfo` was a Phase 1 stub here; Step 5.2 moved it
  // into `Bridge/Routers/preview_router.cpp` where it now reads the
  // .clingfyproj manifest via `clingfy::capture::RecordingProjectReader`
  // and returns the macOS-shaped map.

  table["getZoomSegments"] = &HandleEmptyList;
  table["getManualZoomSegments"] = &HandleEmptyList;
  table["saveManualZoomSegments"] = &HandleSaveManualZoomSegments;
}

}  // namespace clingfy::bridge::routers::export_
