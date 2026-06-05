#include "Bridge/Routers/export_router.h"

#include <cstdint>
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

// ---- Phase 6 / Slice 1 + 2 + 3 ----------------------------------------------
// `exportVideo` and `processVideo` are off the NotImplemented stub.
//   - exportVideo: writes to a Dart-chosen destination directory + filename,
//     forcing a `.mov` extension. layout=auto & resolution=auto with no
//     padding / corner radius take the Slice 1 byte-for-byte copy fast-path;
//     any other layout/resolution/fit — or a non-zero padding / corner
//     radius — routes through the decode → composite → re-encode pipeline
//     (`export_pipeline.h`), which applies the Slice 3 background color /
//     padding / corner radius and carries the source audio through. No
//     progress event yet (cancel + progress land in Slice 5).
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

// Read a Dart `double` arg. The standard codec also lets an integer-valued
// double arrive as int32/int64, so accept those too (a `0` would otherwise
// silently zero the value); anything else returns `fallback`.
double ReadDouble(const flutter::EncodableMap& map, const std::string& key,
                  double fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* d = std::get_if<double>(&it->second)) {
    return *d;
  }
  if (const auto* i = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<double>(*i);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return fallback;
}

// Read a nullable Dart `int?` arg. Returns nullopt when the key is absent
// or `null` (distinct from an explicit 0). Accepts both the int32 and int64
// codec variants — an ARGB color with the alpha high bit set exceeds int32
// range, so Flutter encodes it as int64.
std::optional<std::int64_t> ReadOptionalInt(const flutter::EncodableMap& map,
                                            const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* i = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<std::int64_t>(*i);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) {
    return *i64;
  }
  return std::nullopt;
}

// Read a Dart `bool` arg, returning `fallback` when the key is absent or not
// a bool. (export_router has no shared codec util, so this mirrors the
// recording_router helper of the same name.)
bool ReadBool(const flutter::EncodableMap& map, const std::string& key,
              bool fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* value = std::get_if<bool>(&it->second)) {
    return *value;
  }
  return fallback;
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
    // Slice 3 canvas styling. Padding / corner radius are raw output pixels
    // (passed through unscaled to match macOS); a non-zero value forces the
    // composition path. backgroundColor is a nullable 0xAARRGGBB int —
    // nullopt (Dart null) renders as opaque black.
    input.padding = ReadDouble(*args, "padding", 0.0);
    input.corner_radius = ReadDouble(*args, "cornerRadius", 0.0);
    input.background_color = ReadOptionalInt(*args, "backgroundColor");
    // Slice 4 audio. Fallbacks MUST equal the macOS identity defaults
    // (0 dB / 100% / off / -16 dBFS) so an absent arg is a no-op that keeps
    // the byte-copy fast-path — volume 100.0 in particular, not 0.0.
    input.audio_gain_db = ReadDouble(*args, "audioGainDb", 0.0);
    input.audio_volume_percent = ReadDouble(*args, "audioVolumePercent", 100.0);
    input.auto_normalize = ReadBool(*args, "autoNormalizeOnExport", false);
    input.target_loudness_dbfs = ReadDouble(*args, "targetLoudnessDbfs", -16.0);
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
    case clingfy::capture::export_::PassthroughError::kRenderFailed:
      // The composition (decode -> composite -> re-encode) path that
      // Slice 3's padding / corner radius / non-auto layout force every
      // styled export through reports failures as kRenderFailed; map it to
      // the same generic EXPORT_ERROR macOS uses (export_passthrough.h
      // documents kRenderFailed as "Maps to EXPORT_ERROR").
      result->Error(error::kExportError, outcome.message,
                    flutter::EncodableValue(input.project_path));
      return;
    default:
      // Every PassthroughError MUST complete the MethodResult. An
      // un-answered result is destroyed silently and the Dart
      // `exportVideo` future never resolves — the export UI hangs with no
      // error. This default guards any future enum value from
      // reintroducing that hang (MSVC's C4061/C4062 do not fire at /W4).
      result->Error(error::kExportError,
                    outcome.message.empty() ? "exportVideo: unknown export "
                                              "failure"
                                            : outcome.message,
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
