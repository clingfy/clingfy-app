#include "Bridge/Routers/recording_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::recording {

namespace {

void HandleStartRecording(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::NotImplemented(*result, call.method_name());
}

void HandleStopRecording(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::NotImplemented(*result, call.method_name());
}

// Pause / resume / togglePause are routed but treated as no-op success in
// Phase 1: there is no active recording to pause, and the Flutter side fires
// them only after a successful startRecording (which will already have
// errored). Returning success keeps the call cheap and avoids spurious error
// toasts if the Flutter UI re-issues them defensively.
void HandlePauseResume(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

// `RecordingPauseResumeCapabilities.fromMap` reads `canPauseResume`,
// `backend`, `strategy`. Returning `{canPauseResume:false,
// backend:"windows-stub", strategy:"unsupported"}` tells the UI that
// pause/resume is not offered on Windows yet.
void HandleGetRecordingCapabilities(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap value{
      {flutter::EncodableValue("canPauseResume"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("backend"),
       flutter::EncodableValue("windows-stub")},
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
// loopback is wired up in Phase 3.
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
