#include "Bridge/Routers/recording_router.h"

#include <flutter/encodable_value.h>

#include <optional>
#include <string>

#include "Bridge/native_error_codes.h"
#include "Bridge/result_helpers.h"
#include "Capture/recording_engine.h"

namespace clingfy::bridge::routers::recording {

namespace {

// ---- Argument-parsing helpers ---------------------------------------------
//
// The Dart side encodes startRecording / stopRecording arguments as an
// `EncodableMap`. These helpers pull typed values out with sensible defaults
// so the engine receives a fully populated `StartRecordingRequest` even
// when older Dart clients omit newer fields.

const flutter::EncodableMap* AsMap(
    const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableMap>(arguments);
}

std::string ReadString(const flutter::EncodableMap& map,
                       const std::string& key,
                       const std::string& fallback = {}) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return fallback;
}

std::int32_t ReadInt32(const flutter::EncodableMap& map,
                       const std::string& key,
                       std::int32_t fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* value = std::get_if<std::int32_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<std::int64_t>(&it->second)) {
    return static_cast<std::int32_t>(*value);
  }
  return fallback;
}

bool ReadBool(const flutter::EncodableMap& map,
              const std::string& key,
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

// ---- Handlers --------------------------------------------------------------

void HandleStartRecording(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = AsMap(call.arguments());
  if (args == nullptr) {
    reply::BadArgs(*result,
                   "startRecording requires a map argument with sessionId.");
    return;
  }

  clingfy::capture::StartRecordingRequest request;
  request.session_id = ReadString(*args, "sessionId");
  request.frame_rate = ReadInt32(*args, "frameRate", 30);
  request.system_audio_enabled =
      ReadBool(*args, "systemAudioEnabled", false);
  request.disable_microphone = ReadBool(*args, "disableMicrophone", false);
  request.disable_camera_overlay =
      ReadBool(*args, "disableCameraOverlay", true);
  request.disable_cursor_highlight =
      ReadBool(*args, "disableCursorHighlight", true);
  request.allow_low_storage_bypass =
      ReadBool(*args, "allowLowStorageBypass", false);

  auto error = clingfy::capture::RecordingEngine::Instance().Start(
      std::move(request));
  if (error) {
    result->Error(error->code, error->message);
    return;
  }
  reply::Null(*result);
}

void HandleStopRecording(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (const auto* args = AsMap(call.arguments())) {
    session_id = ReadString(*args, "sessionId");
  }

  auto error =
      clingfy::capture::RecordingEngine::Instance().Stop(session_id);
  if (error) {
    result->Error(error->code, error->message);
    return;
  }
  reply::Null(*result);
}

// Pause / resume / togglePause are routed but treated as no-op success in
// Phase 3A: pause/resume support lands in Phase 4. Returning success keeps
// the call cheap and avoids spurious error toasts if the Flutter UI re-issues
// them defensively.
void HandlePauseResume(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

// `RecordingPauseResumeCapabilities.fromMap` reads `canPauseResume`,
// `backend`, `strategy`. Phase 3A tells the UI the Windows engine is
// running on Media Foundation but pause/resume is not yet wired up.
void HandleGetRecordingCapabilities(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap value{
      {flutter::EncodableValue("canPauseResume"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("backend"),
       flutter::EncodableValue("windows_mf")},
      {flutter::EncodableValue("strategy"),
       flutter::EncodableValue("unsupported")},
  };
  reply::Map(*result, std::move(value));
}

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

void HandleGetExcludeRecorderApp(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Bool(*result, false);
}

// macOS default is `true` (exclude mic from the system-audio mix so the user
// doesn't hear themselves echoed back). Mirror that default until WASAPI
// loopback is wired up in Phase 3D.
void HandleGetExcludeMicFromSystemAudio(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Bool(*result, true);
}

void HandleGetCaptureDiagnostics(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::EmptyMap(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["startRecording"] = &HandleStartRecording;
  table["stopRecording"] = &HandleStopRecording;
  table["pauseRecording"] = &HandlePauseResume;
  table["resumeRecording"] = &HandlePauseResume;
  table["togglePauseRecording"] = &HandlePauseResume;
  table["getRecordingCapabilities"] = &HandleGetRecordingCapabilities;

  table["setRecordingQuality"] = &HandleNoopSetter;
  table["setFileNameTemplate"] = &HandleNoopSetter;
  table["setExcludeRecorderApp"] = &HandleNoopSetter;
  table["setExcludeMicFromSystemAudio"] = &HandleNoopSetter;
  table["setCaptureFrameRate"] = &HandleNoopSetter;

  table["getExcludeRecorderApp"] = &HandleGetExcludeRecorderApp;
  table["getExcludeMicFromSystemAudio"] = &HandleGetExcludeMicFromSystemAudio;
  table["getCaptureDiagnostics"] = &HandleGetCaptureDiagnostics;
}

}  // namespace clingfy::bridge::routers::recording
