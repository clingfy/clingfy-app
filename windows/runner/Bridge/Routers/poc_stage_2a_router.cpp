#include "Bridge/Routers/poc_stage_2a_router.h"

#include <windows.h>

#include <string>

#include "Bridge/result_helpers.h"
#include "preview/poc_stage_2a/stage2a_texture_bridge.h"

namespace clingfy::bridge::routers::poc_stage_2a {

namespace {

using clingfy::poc::stage2a::Stage2aTextureBridge;
using clingfy::poc::stage2a::StartArgs;

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
  StartArgs args{};
  if (const auto* map =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    args.video_path = Utf8ToWide(ReadString(*map, "videoPath"));
    args.cursor_path = Utf8ToWide(ReadString(*map, "cursorPath"));
  }
  auto* bridge = Stage2aTextureBridge::Instance();
  const auto r = bridge->Start(args);

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
  clingfy::poc::stage2a::StopArgs args{};
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
  auto* bridge = Stage2aTextureBridge::Instance();
  bridge->Stop(args);
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["pocStage2aStart"] = &HandlePocStage2aStart;
  table["pocStage2aStop"] = &HandlePocStage2aStop;
}

}  // namespace clingfy::bridge::routers::poc_stage_2a
