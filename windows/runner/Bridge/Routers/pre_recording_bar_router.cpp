#include "Bridge/Routers/pre_recording_bar_router.h"

#include <cstdint>
#include <string>
#include <variant>

#include "Bridge/result_helpers.h"
#include "Capture/PreRecordingBar/pre_recording_bar_controller.h"
#include "Capture/PreRecordingBar/pre_recording_bar_model.h"

namespace clingfy::bridge::routers::pre_recording_bar {

namespace {

const flutter::EncodableMap* AsMap(const flutter::EncodableValue* args) {
  return args != nullptr ? std::get_if<flutter::EncodableMap>(args) : nullptr;
}

int ReadInt(const flutter::EncodableMap& map, const std::string& key,
            int fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* v = std::get_if<std::int32_t>(&it->second)) {
    return *v;
  }
  if (const auto* v = std::get_if<std::int64_t>(&it->second)) {
    return static_cast<int>(*v);
  }
  return fallback;
}

bool ReadBool(const flutter::EncodableMap& map, const std::string& key,
              bool fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* v = std::get_if<bool>(&it->second)) {
    return *v;
  }
  return fallback;
}

clingfy::capture::PreRecordingBarController& Bar() {
  return clingfy::capture::PreRecordingBarController::Instance();
}

// setPreRecordingBarEnabled / setPreRecordingBarVisible — the Settings floating
// control-bar toggle. Both Dart methods carry `{enabled: bool}` (Dart's
// setPreRecordingBarVisible forwards to setPreRecordingBarEnabled); macOS routes
// both through one handler, so mirror that here. Missing/!map defaults to true.
void HandleSetEnabled(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  bool enabled = true;
  if (const auto* args = AsMap(call.arguments())) {
    enabled = ReadBool(*args, "enabled", true);
  }
  Bar().SetEnabled(enabled);
  reply::Null(*result);
}

// showPreRecordingBar — explicit show (clears the per-cycle dismissed flag). No
// args.
void HandleShow(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Bar().Show();
  reply::Null(*result);
}

// togglePreRecordingBar — hide when visible, show when hidden. No args.
void HandleToggle(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Bar().Toggle();
  reply::Null(*result);
}

// setPreRecordingBarState — the full render-state feed. Dart ships the whole map
// as the call arguments (not wrapped). Parse the subset the bar renders from
// (the selected*Id keys are for the Slice 6 pickers and are ignored here).
void HandleSetState(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args = AsMap(call.arguments())) {
    clingfy::capture::PreRecordingBarInputs inputs;
    inputs.phase = ReadInt(*args, "phase", 0);
    inputs.target_mode = ReadInt(*args, "targetMode", 0);
    inputs.camera_selected = ReadBool(*args, "cameraEnabled", false);
    inputs.mic_enabled = ReadBool(*args, "micEnabled", false);
    inputs.system_audio_enabled = ReadBool(*args, "systemAudioEnabled", false);
    inputs.update_available = ReadBool(*args, "updateAvailable", false);
    inputs.can_pause_resume = ReadBool(*args, "canPauseResume", false);
    inputs.pause_resume_in_flight =
        ReadBool(*args, "pauseResumeInFlight", false);
    inputs.countdown_active = ReadBool(*args, "countdownActive", false);
    Bar().SetState(inputs);
  }
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  // macOS routes both enabled + visible through the same handler; mirror that.
  table["setPreRecordingBarEnabled"] = &HandleSetEnabled;
  table["setPreRecordingBarVisible"] = &HandleSetEnabled;
  table["showPreRecordingBar"] = &HandleShow;
  table["togglePreRecordingBar"] = &HandleToggle;
  table["setPreRecordingBarState"] = &HandleSetState;
}

}  // namespace clingfy::bridge::routers::pre_recording_bar
