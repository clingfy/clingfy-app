#include "Bridge/Routers/recording_router.h"

#include <flutter/encodable_value.h>

#include <atomic>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>

#include "Bridge/native_error_codes.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Bridge/result_helpers.h"
#include "Capture/recording_engine.h"
#include "Services/recovery_sweep.h"

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

// Phase 4 wires pause / resume / togglePause onto the live engine.
// togglePauseRecording drives the engine into whichever state is the
// opposite of the current one — its bridge contract is "if recording,
// pause; if paused, resume".
void HandlePauseRecording(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (const auto* args = AsMap(call.arguments())) {
    session_id = ReadString(*args, "sessionId");
  }
  auto error =
      clingfy::capture::RecordingEngine::Instance().Pause(session_id);
  if (error) {
    result->Error(error->code, error->message);
    return;
  }
  reply::Null(*result);
}

void HandleResumeRecording(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (const auto* args = AsMap(call.arguments())) {
    session_id = ReadString(*args, "sessionId");
  }
  auto error =
      clingfy::capture::RecordingEngine::Instance().Resume(session_id);
  if (error) {
    result->Error(error->code, error->message);
    return;
  }
  reply::Null(*result);
}

void HandleTogglePauseRecording(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (const auto* args = AsMap(call.arguments())) {
    session_id = ReadString(*args, "sessionId");
  }
  // Snapshot the engine state to decide which way to flip. The engine
  // calls themselves are idempotent and re-check state under their own
  // mutex, so a tiny race here just produces one extra Pause/Resume
  // event — harmless.
  const auto state =
      clingfy::capture::RecordingEngine::Instance().state();
  std::optional<clingfy::capture::RecordingError> error;
  if (state == clingfy::capture::RecordingState::kPaused ||
      state == clingfy::capture::RecordingState::kPausing) {
    error = clingfy::capture::RecordingEngine::Instance().Resume(session_id);
  } else {
    error = clingfy::capture::RecordingEngine::Instance().Pause(session_id);
  }
  if (error) {
    result->Error(error->code, error->message);
    return;
  }
  reply::Null(*result);
}

// `RecordingPauseResumeCapabilities.fromMap` reads `canPauseResume`,
// `backend`, `strategy`. Phase 4 flips the boolean to `true` (the
// engine now drives WASAPI Stop/Start + the WGC drop-frame path +
// the RecordingClock skip-the-gap math) and reports a Windows-
// specific strategy identifier so diagnostics can surface which
// pause path is in use.
void HandleGetRecordingCapabilities(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap value{
      {flutter::EncodableValue("canPauseResume"),
       flutter::EncodableValue(true)},
      {flutter::EncodableValue("backend"),
       flutter::EncodableValue("windows_mf")},
      {flutter::EncodableValue("strategy"),
       flutter::EncodableValue("windows_mf_pause")},
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

// Phase 3E: surface the engine's live capture diagnostics. The keys
// here match the macOS `StorageDiagnosticsService` shape
// (`backend`, `captureFps`, free-space counters) where the meaning
// translates, and add Windows-specific extras for the audio counters
// the engine now tracks. Free-space keys are intentionally omitted on
// Windows for Phase 3E — the recordings root lookup needs
// `GetDiskFreeSpaceExW` plumbing, which lands with the rest of the
// storage UX in Phase 10.
void HandleGetCaptureDiagnostics(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto diag =
      clingfy::capture::RecordingEngine::Instance().Diagnostics();
  flutter::EncodableMap map{
      {flutter::EncodableValue("backend"),
       flutter::EncodableValue("windows_mf")},
      {flutter::EncodableValue("frameWidth"),
       flutter::EncodableValue(static_cast<std::int64_t>(diag.frame_width))},
      {flutter::EncodableValue("frameHeight"),
       flutter::EncodableValue(static_cast<std::int64_t>(diag.frame_height))},
      {flutter::EncodableValue("framesReceived"),
       flutter::EncodableValue(
           static_cast<std::int64_t>(diag.frames_received))},
      {flutter::EncodableValue("framesDropped"),
       flutter::EncodableValue(
           static_cast<std::int64_t>(diag.frames_dropped))},
      {flutter::EncodableValue("videoSamplesWritten"),
       flutter::EncodableValue(
           static_cast<std::int64_t>(diag.samples_written))},
      {flutter::EncodableValue("audioSamplesWritten"),
       flutter::EncodableValue(
           static_cast<std::int64_t>(diag.audio_samples_written))},
      {flutter::EncodableValue("micActive"),
       flutter::EncodableValue(diag.mic_active)},
      {flutter::EncodableValue("loopbackActive"),
       flutter::EncodableValue(diag.loopback_active)},
      {flutter::EncodableValue("micPackets"),
       flutter::EncodableValue(
           static_cast<std::int64_t>(diag.mic_packets))},
      {flutter::EncodableValue("loopbackPackets"),
       flutter::EncodableValue(
           static_cast<std::int64_t>(diag.loopback_packets))},
      {flutter::EncodableValue("outputPath"),
       flutter::EncodableValue(diag.output_path)},
  };
  reply::Map(*result, std::move(map));
}

// Phase 10.4 (review fix): the sweep worker must NOT outlive CRT static
// destruction — it touches Meyers singletons (NativeLogPublisher, the
// dispatcher). Same shape as temp_orphan_scan's ScanThreadHolder: a
// function-local static joins the worker at process teardown, with a
// cancel flag the sweep polls between filesystem entries. `running` keeps
// a defensive second call from blocking the platform thread on a join of a
// still-working sweep.
struct SweepThreadHolder {
  std::atomic<bool> cancel{false};
  std::atomic<bool> running{false};
  std::thread worker;
  ~SweepThreadHolder() {
    cancel.store(true);
    if (worker.joinable()) worker.join();
  }
};

SweepThreadHolder& SweepHolder() {
  static SweepThreadHolder holder;
  return holder;
}

}  // namespace

// Phase 10.4: the startup recovery sweep. Marks crash-interrupted projects
// failed (provisional `status: "capturing"` manifests whose owner process is
// dead) and deletes stranded `%TEMP%\clingfy_*` files, then reports what it
// found so Dart can show the user a notice. Dart calls this once after the
// home shell mounts. The filesystem walks run on a worker thread; the reply
// is marshaled back to the platform thread (the export_router pattern).
void HandleGetStartupRecoveryReport(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  (void)call;

  const auto run_sweep = []() -> flutter::EncodableValue {
    clingfy::services::RecoverySweepOptions options;
    options.cancel = &SweepHolder().cancel;
    const clingfy::services::RecoverySweepResult sweep =
        clingfy::services::RunRecoverySweep(options);
    flutter::EncodableList interrupted;
    for (const auto& project : sweep.interrupted) {
      interrupted.push_back(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("projectPath"),
           flutter::EncodableValue(project.project_path)},
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(project.session_id)},
      }));
    }
    return flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("interruptedProjects"),
         flutter::EncodableValue(interrupted)},
        {flutter::EncodableValue("cleanedTempFileCount"),
         flutter::EncodableValue(
             static_cast<std::int32_t>(sweep.cleaned_temp_files))},
        {flutter::EncodableValue("cleanedTempBytes"),
         flutter::EncodableValue(
             static_cast<std::int64_t>(sweep.cleaned_temp_bytes))},
    });
  };

  // Defense in depth: never sweep while a recording is in flight (Dart only
  // calls this at startup, but a slow startup can race a fast user).
  if (clingfy::capture::RecordingEngine::Instance().IsSessionActive()) {
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("interruptedProjects"),
         flutter::EncodableValue(flutter::EncodableList{})},
        {flutter::EncodableValue("cleanedTempFileCount"),
         flutter::EncodableValue(0)},
        {flutter::EncodableValue("cleanedTempBytes"),
         flutter::EncodableValue(static_cast<std::int64_t>(0))},
    }));
    return;
  }

  auto& dispatcher = clingfy::bridge::PlatformThreadDispatcher::Instance();
  if (!dispatcher.is_initialized()) {
    // Test / cold-start fallback: run synchronously on the calling thread.
    result->Success(run_sweep());
    return;
  }

  auto& holder = SweepHolder();
  if (holder.running.load()) {
    // A sweep is already in flight (defensive — Dart calls once). Reply an
    // empty report instead of joining (which would block the platform
    // thread) or racing two sweeps.
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("interruptedProjects"),
         flutter::EncodableValue(flutter::EncodableList{})},
        {flutter::EncodableValue("cleanedTempFileCount"),
         flutter::EncodableValue(0)},
        {flutter::EncodableValue("cleanedTempBytes"),
         flutter::EncodableValue(static_cast<std::int64_t>(0))},
    }));
    return;
  }
  if (holder.worker.joinable()) {
    holder.worker.join();  // previous sweep finished; reclaim the thread
  }
  holder.running.store(true);
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>
      shared_result = std::move(result);
  holder.worker = std::thread([run_sweep, shared_result]() {
    const flutter::EncodableValue payload = run_sweep();
    clingfy::bridge::PlatformThreadDispatcher::Instance().Post(
        [shared_result, payload]() { shared_result->Success(payload); });
    SweepHolder().running.store(false);
  });
}

void RegisterHandlers(HandlerTable& table) {
  table["startRecording"] = &HandleStartRecording;
  table["stopRecording"] = &HandleStopRecording;
  table["getStartupRecoveryReport"] = &HandleGetStartupRecoveryReport;
  table["pauseRecording"] = &HandlePauseRecording;
  table["resumeRecording"] = &HandleResumeRecording;
  table["togglePauseRecording"] = &HandleTogglePauseRecording;
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
