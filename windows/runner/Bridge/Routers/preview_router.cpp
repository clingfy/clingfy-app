#include "Bridge/Routers/preview_router.h"

#include <windows.h>

#include <fstream>
#include <optional>
#include <sstream>
#include <string>

#include "Bridge/native_error_codes.h"
#include "Bridge/result_helpers.h"
#include "Capture/Camera/camera_meta.h"
#include "Capture/recording_project_reader.h"
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
// EncodableMap arg-extraction helpers — used by the production
// previewOpen / previewClose / getRecordingSceneInfo handlers and the
// deprecated POC alias section that follows.
// ---------------------------------------------------------------------

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

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                        out.data(), needed, nullptr, nullptr);
  return out;
}

double ReadDouble(const flutter::EncodableMap& map, const char* key,
                  double fallback) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<double>(*i);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return fallback;
}

bool ReadBool(const flutter::EncodableMap& map, const char* key,
              bool fallback) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  return fallback;
}

std::optional<std::int64_t> ReadOptionalInt(const flutter::EncodableMap& map,
                                            const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return std::nullopt;
  if (const auto* i = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<std::int64_t>(*i);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) return *i64;
  return std::nullopt;
}

// Read `<dir>/camera.meta.json` content. nullopt when unreadable.
std::optional<std::string> ReadFileUtf8(const std::wstring& path) {
  std::ifstream f(path, std::ios::in | std::ios::binary);
  if (!f.is_open()) return std::nullopt;
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

// Build the live preview camera composition from a Dart `camera*` arg map (the
// keys CameraCompositionState.toMap() emits, shared by processVideo +
// previewSetCameraPlacement). Same shape the export router parses.
clingfy::preview::PreviewCameraComposition ReadCameraComposition(
    const flutter::EncodableMap& args) {
  clingfy::preview::PreviewCameraComposition c;
  c.visible = ReadBool(args, "cameraVisible", false);
  c.layout_preset = ReadString(args, "cameraLayoutPreset");
  c.size_factor = ReadDouble(args, "cameraSizeFactor", 0.18);
  c.shape = ReadString(args, "cameraShape");
  c.corner_radius = ReadDouble(args, "cameraCornerRadius", 0.0);
  c.content_mode = ReadString(args, "cameraContentMode");
  c.mirror = ReadBool(args, "cameraMirror", false);
  c.opacity = ReadDouble(args, "cameraOpacity", 1.0);
  c.border_width = ReadDouble(args, "cameraBorderWidth", 0.0);
  if (const auto argb = ReadOptionalInt(args, "cameraBorderColorArgb")) {
    c.has_border_color = true;
    c.border_argb = static_cast<std::uint32_t>(*argb);
  }
  c.shadow_preset =
      static_cast<int>(ReadDouble(args, "cameraShadowPreset", 0.0));
  if (const auto it = args.find(flutter::EncodableValue("cameraNormalizedCenter"));
      it != args.end()) {
    if (const auto* center = std::get_if<flutter::EncodableMap>(&it->second)) {
      c.has_center = true;
      c.center_x = ReadDouble(*center, "x", 0.0);
      c.center_y = ReadDouble(*center, "y", 0.0);
    }
  }
  return c;
}

// ---------------------------------------------------------------------
// getRecordingSceneInfo — Step 5.2 of the Phase 5 implementation plan.
//
// Reads the `.clingfyproj` manifest via
// `clingfy::capture::RecordingProjectReader` and returns the macOS-
// shaped map. All reader-side errors collapse to `SCENE_INPUT_MISSING`
// (with the offending `projectPath` in the FlutterError details) so
// Dart's `_handleProjectOpenError` flow stays platform-agnostic; the
// specific reader-error variant is emitted to the Windows debugger via
// `OutputDebugStringW` for triage without leaking implementation
// detail across the bridge.
//
// `camera` key is intentionally omitted — the Windows recording engine
// does not currently emit `editorSeed` into screen.meta.json, so there
// is no manifest-derived camera layout state to surface today. Dart's
// `RecordingSceneInfo.fromMap` treats a missing key and a `null`
// identically (`raw['camera'] is Map` → false), which matches the
// macOS handler exactly.
// ---------------------------------------------------------------------

flutter::EncodableMap BuildCameraExportCapabilities() {
  // These flags gate camera-overlay *export styling* in the Dart editor. The
  // slice plan flips them on as each lands:
  //   * 9.4 → shapeMask + cornerRadius (the basic circle / rounded bubble) ✅
  //   * 9.5 → border + shadow ✅
  //   * 9.6 → chromaKey
  // Phase 9.4 composites the camera as a masked circle / rounded-rect / square
  // bubble; Phase 9.5 adds mirror, opacity, a stroked border, and a blurred drop
  // shadow. So shapeMask + cornerRadius + border + shadow are true; chromaKey
  // stays false until 9.6 (the Dart side hides it and the export ignores its
  // args). (mirror / opacity are always-on transforms, not gated by this map.)
  // (Camera *device selection* readiness is a separate concern, surfaced via
  // getVideoSources / setVideoSource + the camera-readiness check, not through
  // this export-styling capabilities map.) The Dart parser defaults a missing
  // key to true, so we emit every key explicitly.
  return flutter::EncodableMap{
      {flutter::EncodableValue("shapeMask"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("cornerRadius"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("border"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("shadow"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("chromaKey"), flutter::EncodableValue(false)},
  };
}

const char* ReadErrorVariantName(clingfy::capture::ReadError e) {
  using clingfy::capture::ReadError;
  switch (e) {
    case ReadError::kNone: return "kNone";
    case ReadError::kBundleNotFound: return "PROJECT_BUNDLE_NOT_FOUND";
    case ReadError::kManifestInvalidJson:
      return "PROJECT_MANIFEST_INVALID_JSON";
    case ReadError::kSchemaVersionMismatch:
      return "PROJECT_SCHEMA_VERSION_MISMATCH";
    case ReadError::kRequiredFileMissing:
      return "PROJECT_REQUIRED_FILE_MISSING";
  }
  return "PROJECT_UNKNOWN_ERROR";
}

void LogSceneInfoReaderError(const std::string& project_path_utf8,
                             const clingfy::capture::ReadResult& read) {
  // OutputDebugStringW surfaces to attached debuggers and to DebugView
  // when running outside a debugger. fprintf(stderr, ...) on a GUI
  // subsystem exe is not reliably reachable. Keep the line ASCII-safe
  // since `OutputDebugStringW` does not interpret line endings.
  std::string line = "[getRecordingSceneInfo] reader=";
  line += ReadErrorVariantName(read.error);
  line += " projectPath=";
  line += project_path_utf8;
  if (!read.message.empty()) {
    line += " — ";
    line += read.message;
  }
  ::OutputDebugStringW(Utf8ToWide(line).c_str());
}

void HandleGetRecordingSceneInfo(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Match macOS: missing or wrong-type `projectPath` → BAD_ARGS with
  // null details. Empty-string projectPath is forwarded through to the
  // reader, which fails with bundle-not-found → SCENE_INPUT_MISSING —
  // also matching macOS.
  const flutter::EncodableMap* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error(error::kBadArgs, "missing projectPath");
    return;
  }
  auto it = args->find(flutter::EncodableValue("projectPath"));
  if (it == args->end() ||
      !std::holds_alternative<std::string>(it->second)) {
    result->Error(error::kBadArgs, "missing projectPath");
    return;
  }
  const std::string project_path_utf8 = std::get<std::string>(it->second);

  const std::wstring project_path_w = Utf8ToWide(project_path_utf8);
  const auto read =
      clingfy::capture::ReadRecordingProject(project_path_w);

  if (read.error != clingfy::capture::ReadError::kNone) {
    LogSceneInfoReaderError(project_path_utf8, read);
    // Single user-visible code mirrors macOS's PreviewSceneResolver:
    //   FlutterError(
    //     code: "SCENE_INPUT_MISSING",
    //     message: "Recording project not found. It may have been moved or deleted.",
    //     details: projectPath)
    result->Error(
        "SCENE_INPUT_MISSING",
        "Recording project not found. It may have been moved or deleted.",
        flutter::EncodableValue(project_path_utf8));
    return;
  }

  const auto& project = *read.project;
  flutter::EncodableMap out{
      {flutter::EncodableValue("projectPath"),
       flutter::EncodableValue(project_path_utf8)},
      {flutter::EncodableValue("screenPath"),
       flutter::EncodableValue(WideToUtf8(project.screen_path))},
      // The reader fails with kRequiredFileMissing when screen.meta.json
      // is absent on disk, so on a successful read the metadata path
      // is always real — match macOS, which only emits this key when
      // the file exists.
      {flutter::EncodableValue("metadataPath"),
       flutter::EncodableValue(WideToUtf8(project.screen_metadata_path))},
      {flutter::EncodableValue("cameraExportCapabilities"),
       flutter::EncodableValue(BuildCameraExportCapabilities())},
  };
  if (project.camera_video_path.has_value()) {
    out[flutter::EncodableValue("cameraPath")] =
        flutter::EncodableValue(WideToUtf8(*project.camera_video_path));
  }
  // Intentionally NO `camera` key — see the function-header comment.
  reply::Map(*result, std::move(out));
}

// ---------------------------------------------------------------------
// previewOpen / previewClose — Step 5.3 of the Phase 5 implementation
// plan, extended in Step 5.5.2 to return the Flutter texture id so the
// Dart UI can mount a `Texture(textureId: ...)` widget.
//
// macOS surfaces its inline preview through an AppKit platform view
// (`AppKitView('inline_preview_view')`) and therefore returns null
// from previewOpen — Flutter does not need a texture id to render an
// AppKit view. Windows has no AppKit; the only path from the
// PreviewEngine's DXGI shared-handle texture to a Flutter widget is
// through the `Texture(textureId:)` widget. Step 5.5.2 returns that
// id here so the Dart side has something to mount.
//
// Reply shape on success (keys match the Swift-side macOS contract
// where applicable; the texture-id key is Windows-specific because
// macOS does not produce one):
//   {
//     "textureId":      int64,   // -1 if allocation failed
//     "width":          int32,   // shared texture size in pixels
//     "height":         int32,
//     "videoWidth":     int32,   // natural video size; 0 until the
//     "videoHeight":    int32,   //   first VideoFrameAvailable arrives
//     "sharedHandleOk": bool,    // DXGI shared-handle success
//   }
// ---------------------------------------------------------------------

void HandlePreviewOpen(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error(error::kBadArgs, "missing args map");
    return;
  }
  const std::string session_id = ReadString(*args, "sessionId");
  const std::string project_path_utf8 = ReadString(*args, "projectPath");

  if (session_id.empty() || project_path_utf8.empty()) {
    result->Error(
        error::kBadArgs,
        "previewOpen requires non-empty sessionId and projectPath");
    return;
  }

  const std::wstring project_path_w = Utf8ToWide(project_path_utf8);
  const auto read =
      clingfy::capture::ReadRecordingProject(project_path_w);
  if (read.error != clingfy::capture::ReadError::kNone) {
    LogSceneInfoReaderError(project_path_utf8, read);
    // Match the macOS PreviewSceneResolver error code + message
    // shape; details echoes the projectPath so the Dart layer can
    // surface "<path> could not be opened" without re-deriving it.
    result->Error(
        "PREVIEW_INPUT_MISSING",
        "Recording project not found. It may have been moved or deleted.",
        flutter::EncodableValue(project_path_utf8));
    return;
  }

  clingfy::preview::OpenArgs open_args{};
  open_args.session_id = session_id;
  open_args.project_path = project_path_utf8;
  open_args.video_path = read.project->screen_path;
  if (read.project->cursor_path.has_value()) {
    open_args.cursor_path = *read.project->cursor_path;
  }
  // Phase 9.6: composite the camera in the preview ONLY when the project has a
  // usable, non-burned-in camera — raw.mov + camera.meta.json present-together
  // (the reader guarantees this), the metadata parses, the live preview was NOT
  // burned into screen.mov, and at least one frame was recorded. Mirrors the
  // export's ShouldCompositeCamera gate so preview and export agree. Otherwise
  // the preview stays camera-free (camera_path left empty).
  if (read.project->camera_video_path.has_value() &&
      read.project->camera_metadata_path.has_value()) {
    if (const auto meta_json =
            ReadFileUtf8(*read.project->camera_metadata_path)) {
      if (const auto meta =
              clingfy::capture::ParseCameraMetaJson(*meta_json);
          meta.has_value() && !meta->preview_burned_in &&
          meta->frames_written > 0) {
        open_args.camera_path = *read.project->camera_video_path;
        open_args.camera_start_offset_ms = meta->start_offset_ms;
      }
    }
  }

  auto* engine = PreviewEngine::Instance();
  const auto r = engine->Open(open_args);
  if (!r.error.empty()) {
    // Engine-side validation rejection (e.g. another session already
    // open, texture allocation failed). Map to the same user-visible
    // code Dart already handles for PREVIEW_INPUT_MISSING — but
    // surface the engine's message in details for triage.
    result->Error(
        "PREVIEW_INPUT_MISSING",
        r.error,
        flutter::EncodableValue(project_path_utf8));
    return;
  }
  flutter::EncodableMap out;
  out[flutter::EncodableValue("textureId")] =
      flutter::EncodableValue(r.texture_id);
  out[flutter::EncodableValue("width")] =
      flutter::EncodableValue(r.width);
  out[flutter::EncodableValue("height")] =
      flutter::EncodableValue(r.height);
  out[flutter::EncodableValue("videoWidth")] =
      flutter::EncodableValue(r.video_width);
  out[flutter::EncodableValue("videoHeight")] =
      flutter::EncodableValue(r.video_height);
  out[flutter::EncodableValue("sharedHandleOk")] =
      flutter::EncodableValue(r.shared_handle_ok);
  reply::Map(*result, std::move(out));
}

void HandlePreviewClose(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    session_id = ReadString(*args, "sessionId");
  }
  // Stale-session close is a silent no-op inside PreviewEngine::Close;
  // missing-args is too. Match macOS's "always reply null" contract.
  clingfy::preview::CloseArgs close_args{};
  close_args.session_id = session_id;
  PreviewEngine::Instance()->Close(close_args);
  reply::Null(*result);
}

// ---------------------------------------------------------------------
// previewPlay / previewPause / previewSeekTo — Step 5.5 transport.
//
// Each handler validates its args and forwards to the corresponding
// PreviewEngine method. Stale-session calls (the engine's
// active_session_id_ mismatches the call's sessionId) are silent
// no-ops inside the engine itself — the router always returns null
// on a successfully-parsed request, matching macOS's contract that
// transport methods never report stale-session errors.
//
// BAD_ARGS is reserved for genuinely malformed inputs: missing args
// map, missing/empty sessionId, missing/wrong-type ms (seek only).
// The Dart-side PlayerController guards against these with its own
// state machine, so BAD_ARGS in practice surfaces only as a
// development-time signal that someone called the bridge with the
// wrong shape.
// ---------------------------------------------------------------------

bool ReadSessionId(const flutter::MethodCall<flutter::EncodableValue>& call,
                   flutter::MethodResult<flutter::EncodableValue>& result,
                   std::string* out_session_id) {
  const auto* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result.Error(error::kBadArgs, "missing args map");
    return false;
  }
  *out_session_id = ReadString(*args, "sessionId");
  if (out_session_id->empty()) {
    result.Error(error::kBadArgs, "missing sessionId");
    return false;
  }
  return true;
}

void HandlePreviewPlay(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (!ReadSessionId(call, *result, &session_id)) return;
  PreviewEngine::Instance()->Play(session_id);
  reply::Null(*result);
}

void HandlePreviewPause(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (!ReadSessionId(call, *result, &session_id)) return;
  PreviewEngine::Instance()->Pause(session_id);
  reply::Null(*result);
}

void HandlePreviewSeekTo(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string session_id;
  if (!ReadSessionId(call, *result, &session_id)) return;

  // `ms` must be present and integer-typed. Dart's PlayerController
  // sends `ms` as `int` which serializes to int64 in EncodableValue;
  // we also accept int32 for tolerance against any future Dart
  // changes that might widen / narrow the wire type. Doubles are
  // rejected — the channel contract is integer milliseconds.
  const auto* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error(error::kBadArgs, "missing args map");
    return;
  }
  auto it = args->find(flutter::EncodableValue("ms"));
  if (it == args->end()) {
    result->Error(error::kBadArgs, "missing ms");
    return;
  }
  std::int64_t ms_value = 0;
  if (const auto* ms64 = std::get_if<std::int64_t>(&it->second)) {
    ms_value = *ms64;
  } else if (const auto* ms32 = std::get_if<std::int32_t>(&it->second)) {
    ms_value = *ms32;
  } else {
    result->Error(error::kBadArgs, "ms must be an integer (milliseconds)");
    return;
  }

  PreviewEngine::Instance()->SeekTo(session_id, ms_value);
  reply::Null(*result);
}

// Phase 9.6: live camera-bubble composition for the inline preview. Dart calls
// this on placement drags + styling changes (and processVideo forwards the same
// shape on open). Parses the camera* args and pushes them to the engine, which
// rebuilds the bubble on the next composited frame. Stale-session calls are
// dropped engine-side. Always replies null (matches the void Dart contract).
void HandlePreviewSetCameraPlacement(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    const std::string session_id = ReadString(*args, "sessionId");
    PreviewEngine::Instance()->SetCameraComposition(
        session_id, ReadCameraComposition(*args));
  }
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  // Steps 5.3 + 5.5: previewOpen / previewClose / previewPlay /
  // previewPause / previewSeekTo all drive PreviewEngine now.
  // previewPeekTo (preview-time scrubbing without play) stays a
  // Phase 1 no-op — it's never called from the current Dart preview
  // flow and surfaces in a future editor revision.
  table["previewOpen"] = &HandlePreviewOpen;
  table["previewClose"] = &HandlePreviewClose;
  table["previewPlay"] = &HandlePreviewPlay;
  table["previewPause"] = &HandlePreviewPause;
  table["previewSeekTo"] = &HandlePreviewSeekTo;
  table["previewPeekTo"] = &HandleNoopSetter;

  table["playerPlay"] = &HandleNoopSetter;
  table["playerPause"] = &HandleNoopSetter;
  table["playerSeekTo"] = &HandleNoopSetter;
  table["inlinePreviewStop"] = &HandleNoopSetter;

  table["previewSetCameraPlacement"] = &HandlePreviewSetCameraPlacement;
  table["previewSetZoomSegments"] = &HandleNoopSetter;
  table["previewSetAudioMix"] = &HandleNoopSetter;
  table["previewSetAudioGainDb"] = &HandleNoopSetter;

  table["previewGetZoomCapabilities"] = &HandleGetZoomCapabilities;
  table["previewGetCursorSamples"] = &HandleGetCursorSamples;
  table["previewGetSourceDimensions"] = &HandleGetSourceDimensions;

  // Step 5.2: real getRecordingSceneInfo backed by RecordingProjectReader.
  // Was a Phase 1 stub in Bridge/Routers/export_router.cpp until 5.2.
  table["getRecordingSceneInfo"] = &HandleGetRecordingSceneInfo;
}

}  // namespace clingfy::bridge::routers::preview
