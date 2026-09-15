#include "Bridge/Routers/devices_router.h"

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "Bridge/Devices/audio_source_enumerator.h"
#include "Bridge/Devices/device_record.h"
#include "Bridge/Devices/display_enumerator.h"
#include "Bridge/Devices/video_source_enumerator.h"
#include "Bridge/Devices/window_enumerator.h"
#include "Bridge/result_helpers.h"
#include "Capture/windows_selection_state.h"
#include "Overlay/area_picker_overlay.h"
#include "Overlay/display_identify_overlay.h"

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

// ---- Argument helpers ------------------------------------------------------
//
// The setter handlers all receive an `EncodableMap` payload with a single
// key (`id`, `windowId`, or `mode`). These helpers pull the typed value out
// with a `std::nullopt` fallback so a null / missing value is treated as
// "clear the selection" instead of a parse failure.

const flutter::EncodableMap* AsMap(
    const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableMap>(arguments);
}

std::optional<std::int64_t> ReadOptionalInt(const flutter::EncodableMap& map,
                                            const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<std::int64_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<std::int64_t>(*value);
  }
  return std::nullopt;
}

std::optional<std::string> ReadOptionalString(
    const flutter::EncodableMap& map, const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    if (value->empty()) {
      return std::nullopt;
    }
    return *value;
  }
  return std::nullopt;
}

void HandleGetDisplays(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::List(*result,
              Encode(clingfy::bridge::devices::EnumerateDisplays()));
}

// Converts a UTF-8 string to UTF-16 for the Win32 text APIs.
std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return {};
  }
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) {
    return {};
  }
  std::wstring out(static_cast<std::size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                        static_cast<int>(utf8.size()), out.data(), needed);
  return out;
}

void HandleIdentifyDisplays(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  int duration = 1600;
  bool only = false;
  std::optional<std::int64_t> only_id;
  std::map<std::int64_t, std::wstring> labels;

  if (const auto* args = AsMap(call.arguments())) {
    if (const auto raw = ReadOptionalInt(*args, "durationMs")) {
      duration = static_cast<int>(
          (std::max)(std::int64_t{400}, (std::min)(std::int64_t{6000}, *raw)));
    }
    const auto only_it = args->find(flutter::EncodableValue("only"));
    if (only_it != args->end()) {
      if (const auto* flag = std::get_if<bool>(&only_it->second)) {
        only = *flag;
      }
    }
    only_id = ReadOptionalInt(*args, "onlyDisplayId");

    const auto labels_it = args->find(flutter::EncodableValue("labels"));
    if (labels_it != args->end()) {
      if (const auto* map =
              std::get_if<flutter::EncodableMap>(&labels_it->second)) {
        for (const auto& entry : *map) {
          const auto* key = std::get_if<std::string>(&entry.first);
          const auto* value = std::get_if<std::string>(&entry.second);
          if (key == nullptr || value == nullptr || value->empty()) {
            continue;
          }
          // strtoll, not stoll: the runner is built with _HAS_EXCEPTIONS=0,
          // so a throwing parse would terminate rather than be caught.
          char* end = nullptr;
          const long long parsed = std::strtoll(key->c_str(), &end, 10);
          if (end != key->c_str() && end != nullptr && *end == '\0') {
            labels[static_cast<std::int64_t>(parsed)] = WideFromUtf8(*value);
          }
        }
      }
    }
  }

  const auto displays = clingfy::bridge::devices::EnumerateDisplays();

  std::optional<std::int64_t> target;
  if (only) {
    target = only_id;
    if (!target) {
      // The "Main display" row: flash whatever THIS platform would actually
      // capture right now. On Windows that is ResolveHMonitor(nullopt), the
      // primary monitor — resolving it natively is the only honest way to
      // confirm a row whose meaning differs per platform.
      if (const auto primary =
              clingfy::bridge::devices::ResolveHMonitor(std::nullopt)) {
        for (const auto& display : displays) {
          const auto handle =
              clingfy::bridge::devices::ResolveHMonitor(display.id);
          if (handle && *handle == *primary) {
            target = display.id;
            break;
          }
        }
      }
    }
  }

  std::vector<clingfy::overlay::IdentifyTarget> overlay_targets;
  for (const auto& display : displays) {
    if (only && (!target || *target != display.id)) {
      continue;
    }
    const auto handle = clingfy::bridge::devices::ResolveHMonitor(display.id);
    if (!handle) {
      continue;
    }
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (::GetMonitorInfoW(*handle, &info) == 0) {
      continue;
    }
    const auto label_it = labels.find(display.id);
    overlay_targets.push_back(
        {*handle, info.rcMonitor, static_cast<int>(display.ordinal),
         label_it != labels.end() ? label_it->second
                                  : WideFromUtf8(display.name)});
  }

  clingfy::overlay::ShowDisplayIdentify(overlay_targets, duration);
  // Reply with the snapshot that was painted, so Dart adopts exactly what is
  // on the glass and the two can never disagree.
  reply::List(*result, Encode(displays));
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

// ---- Phase 3B / 7 / 9 selection setters ------------------------------------
//
// These setters feed `WindowsSelectionState`, which the `RecordingEngine`
// reads at Start time (display / target mode / audio in 3B, window / area in
// 7, camera in 9). Setters the engine still does not consume (audio gain /
// mix, area reveal) stay as the Phase-1 no-op pattern.

void HandleSetDisplay(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::optional<std::int64_t> id;
  if (const auto* args = AsMap(call.arguments())) {
    id = ReadOptionalInt(*args, "id");
  }
  clingfy::capture::WindowsSelectionState::Instance().SetDisplayId(id);
  reply::Null(*result);
}

void HandleSetDisplayTargetMode(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::int32_t raw = 0;
  if (const auto* args = AsMap(call.arguments())) {
    if (const auto mode = ReadOptionalInt(*args, "mode")) {
      raw = static_cast<std::int32_t>(*mode);
    }
  }
  clingfy::capture::WindowsSelectionState::Instance().SetTargetMode(
      clingfy::capture::TargetModeFromInt(raw));
  reply::Null(*result);
}

void HandleSetAudioSource(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::optional<std::string> id;
  if (const auto* args = AsMap(call.arguments())) {
    id = ReadOptionalString(*args, "id");
  }
  clingfy::capture::WindowsSelectionState::Instance().SetMicrophoneId(id);
  reply::Null(*result);
}

// Phase 9.1: record the selected camera device. Dart sends `{id: <symbolic
// link>}` (the Media Foundation id from getVideoSources) or null / "" to clear.
// The empty-string → nullopt mapping in ReadOptionalString means deselecting in
// the UI clears the native selection. The id is resolved + revalidated against
// the live device list at Start time (Phase 9.2), so storing a stale id here is
// harmless — mirroring how the window / display ids are handled.
void HandleSetVideoSource(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::optional<std::string> id;
  if (const auto* args = AsMap(call.arguments())) {
    id = ReadOptionalString(*args, "id");
  }
  clingfy::capture::WindowsSelectionState::Instance().SetVideoSourceId(id);
  reply::Null(*result);
}

// Phase 7.1: record the selected window target. Dart sends `{windowId: <int>}`
// (the HWND-as-int64 from getAppWindows) or null to clear. The engine resolves
// + revalidates the HWND at Start time, so a stale handle here is harmless.
void HandleSetAppWindowTarget(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::optional<std::int64_t> window_id;
  if (const auto* args = AsMap(call.arguments())) {
    window_id = ReadOptionalInt(*args, "windowId");
  }
  clingfy::capture::WindowsSelectionState::Instance().SetAppWindowId(window_id);
  reply::Null(*result);
}

// Phase 7.3: launch the native drag-to-select overlay (modal — blocks the
// platform thread until the user confirms or cancels), store the picked region,
// and return the macOS-shaped {displayId,x,y,width,height} map. A cancel (Esc /
// right-click / too-small drag) clears the selection and returns null, which
// Dart treats as a cancel. The selection is monitor-local physical pixels;
// RecordingEngine::Start clamps + even-aligns it against the monitor at capture
// time. (This handler is not unit-tested — the modal loop would hang a test; its
// selection math lives in area_picker_geometry and IS unit-tested.)
void HandlePickAreaRecordingRegion(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto picked = clingfy::overlay::PickArea();
  if (!picked.has_value()) {
    clingfy::capture::WindowsSelectionState::Instance().SetAreaRegion(
        std::nullopt);
    reply::Null(*result);
    return;
  }

  clingfy::capture::AreaRegion region;
  // display_id 0 means the overlay could not match the picked monitor to an
  // enumerator id (a config race) — store nullopt so Start resolves the primary.
  region.display_id = picked->display_id != 0
                          ? std::optional<std::int64_t>(picked->display_id)
                          : std::nullopt;
  region.x = picked->x;
  region.y = picked->y;
  region.width = picked->width;
  region.height = picked->height;
  clingfy::capture::WindowsSelectionState::Instance().SetAreaRegion(region);

  flutter::EncodableMap out;
  // Always present (>= 0) so the Dart client's result['displayId'] force-unwrap
  // never throws.
  out[flutter::EncodableValue("displayId")] =
      flutter::EncodableValue(picked->display_id);
  out[flutter::EncodableValue("x")] =
      flutter::EncodableValue(static_cast<std::int64_t>(picked->x));
  out[flutter::EncodableValue("y")] =
      flutter::EncodableValue(static_cast<std::int64_t>(picked->y));
  out[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<std::int64_t>(picked->width));
  out[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<std::int64_t>(picked->height));
  reply::Map(*result, std::move(out));
}

void HandleClearAreaRecordingSelection(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  clingfy::capture::WindowsSelectionState::Instance().SetAreaRegion(
      std::nullopt);
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  // Discovery — real enumeration in Phase 2.
  table["getDisplays"] = &HandleGetDisplays;
  table["identifyDisplays"] = &HandleIdentifyDisplays;
  table["getAppWindows"] = &HandleGetAppWindows;
  table["getAudioSources"] = &HandleGetAudioSources;
  table["getVideoSources"] = &HandleGetVideoSources;

  // Selection — Phase 3B starts honoring these. The engine reads a
  // snapshot at Start time; Phase 3D will start consuming the audio
  // selections, Phase 4/7 the window / area selections.
  table["setDisplay"] = &HandleSetDisplay;
  table["setDisplayTargetMode"] = &HandleSetDisplayTargetMode;
  table["setAudioSource"] = &HandleSetAudioSource;

  // Phase 7.1: window target is now consumed by the engine (window recording).
  table["setAppWindowTarget"] = &HandleSetAppWindowTarget;
  // Phase 9.1: camera selection is now stored in WindowsSelectionState. The
  // engine starts consuming it in Phase 9.2 (camera capture).
  table["setVideoSource"] = &HandleSetVideoSource;

  // Audio gain / mix. `updateAudioPreview` moved to preview_router in
  // editing step 4-7d (it drives PreviewEngine::SetAudioMix now); these two
  // legacy names stay accepted no-ops.
  table["setAudioMix"] = &HandleNoopSetter;
  table["setAudioGainDb"] = &HandleNoopSetter;

  // Area selection lifecycle. Phase 7.2 makes pick/clear real (engine consumes
  // the region); reveal (the post-select preview border) is overlay work, so it
  // stays a no-op until Phase 7.3 brings the native overlay.
  table["pickAreaRecordingRegion"] = &HandlePickAreaRecordingRegion;
  table["revealAreaRecordingRegion"] = &HandleNoopSetter;
  table["clearAreaRecordingSelection"] = &HandleClearAreaRecordingSelection;
}

}  // namespace clingfy::bridge::routers::devices
