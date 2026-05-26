#include "Bridge/Routers/preview_router.h"

#include <windows.h>

#include <string>

#include "Bridge/result_helpers.h"
#include "preview/preview_engine.h"

namespace clingfy::bridge::routers::preview {

namespace {

using clingfy::preview::PreviewEngine;

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

// ---------------------------------------------------------------------
// Deprecated POC Stage 2A aliases.
//
// pocStage2aStart / pocStage2aStop were the POC-only entry points the
// dart-define-gated debug screen (lib/app/debug/poc_stage_2a_screen.dart)
// uses to drive the underlying texture bridge. Step 5.0 of the Phase 5
// implementation plan lifted that bridge out of poc_stage_2a/ into the
// production preview/ tree and renamed it to PreviewEngine; the method
// names stay registered here as deprecated aliases so the debug screen
// continues to work for benchmarking through Steps 5.1 / 5.2 / 5.3.
//
// When Step 5.3 lands the real previewOpen / previewClose semantics
// (sessionId + projectPath, manifest reader, production texture
// lifecycle), the debug screen + these aliases are deleted in the same
// PR. The Dart bridge contract list keeps the method names registered
// during the deprecation window — see
// windows/runner_tests/bridge_contract_coverage_test.cpp.
// ---------------------------------------------------------------------

double ReadDouble(const flutter::EncodableMap& map, const char* key,
                  double fallback) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (std::holds_alternative<double>(it->second)) {
    return std::get<double>(it->second);
  }
  if (std::holds_alternative<int32_t>(it->second)) {
    return static_cast<double>(std::get<int32_t>(it->second));
  }
  if (std::holds_alternative<int64_t>(it->second)) {
    return static_cast<double>(std::get<int64_t>(it->second));
  }
  return fallback;
}

int64_t ReadInt(const flutter::EncodableMap& map, const char* key,
                int64_t fallback) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (std::holds_alternative<int64_t>(it->second)) {
    return std::get<int64_t>(it->second);
  }
  if (std::holds_alternative<int32_t>(it->second)) {
    return std::get<int32_t>(it->second);
  }
  return fallback;
}

std::string ReadString(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return {};
  if (std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return {};
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
  if (needed <= 0) return {};
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                        out.data(), needed);
  return out;
}

void HandlePocStage2aStart(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  clingfy::preview::OpenArgs args{};
  if (const auto* map =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    args.video_path = Utf8ToWide(ReadString(*map, "videoPath"));
    args.cursor_path = Utf8ToWide(ReadString(*map, "cursorPath"));
  }
  auto* engine = PreviewEngine::Instance();
  const auto r = engine->Open(args);

  flutter::EncodableList extensions;
  for (const auto& ext : r.egl_extensions) {
    extensions.push_back(flutter::EncodableValue(ext));
  }
  flutter::EncodableMap out{
      {flutter::EncodableValue("textureId"),
       flutter::EncodableValue(r.texture_id)},
      {flutter::EncodableValue("sharedHandleOk"),
       flutter::EncodableValue(r.shared_handle_ok)},
      {flutter::EncodableValue("eglExtensions"),
       flutter::EncodableValue(std::move(extensions))},
      {flutter::EncodableValue("width"),
       flutter::EncodableValue(r.width)},
      {flutter::EncodableValue("height"),
       flutter::EncodableValue(r.height)},
      {flutter::EncodableValue("videoWidth"),
       flutter::EncodableValue(r.video_width)},
      {flutter::EncodableValue("videoHeight"),
       flutter::EncodableValue(r.video_height)},
      {flutter::EncodableValue("cursorEventCount"),
       flutter::EncodableValue(r.cursor_event_count)},
      {flutter::EncodableValue("cursorMode"),
       flutter::EncodableValue(r.cursor_mode)},
  };
  if (!r.error.empty()) {
    out[flutter::EncodableValue("error")] =
        flutter::EncodableValue(r.error);
  }
  reply::Map(*result, std::move(out));
}

void HandlePocStage2aStop(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  clingfy::preview::CloseArgs args{};
  if (const auto* map =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    args.build_median_ms = ReadDouble(*map, "buildMedianMs", 0.0);
    args.build_p99_ms = ReadDouble(*map, "buildP99Ms", 0.0);
    args.raster_median_ms = ReadDouble(*map, "rasterMedianMs", 0.0);
    args.raster_p99_ms = ReadDouble(*map, "rasterP99Ms", 0.0);
    args.total_median_ms = ReadDouble(*map, "totalMedianMs", 0.0);
    args.total_p99_ms = ReadDouble(*map, "totalP99Ms", 0.0);
    args.flutter_frames_observed = ReadInt(*map, "flutterFramesObserved", 0);
  }
  auto* engine = PreviewEngine::Instance();
  engine->Close(args);
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

  // Deprecated POC Stage 2A aliases — remove in Step 5.3.
  table["pocStage2aStart"] = &HandlePocStage2aStart;
  table["pocStage2aStop"] = &HandlePocStage2aStop;
}

}  // namespace clingfy::bridge::routers::preview
