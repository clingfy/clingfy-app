#include "Bridge/Routers/preview_router.h"

#include <windows.h>

#include <fstream>
#include <optional>
#include <sstream>
#include <string>

#include "Bridge/Routers/clip_args.h"
#include "Bridge/Routers/color_grade_args.h"
#include "Bridge/native_error_codes.h"
#include "Bridge/native_log_publisher.h"
#include "Bridge/result_helpers.h"
#include "Capture/Camera/camera_meta.h"
#include "Capture/Export/audio_sidecar_probe.h"
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
  // Phase 9.7 chroma key (previewed for WYSIWYG with the export).
  c.chroma_enabled = ReadBool(args, "cameraChromaKeyEnabled", false);
  c.chroma_strength = ReadDouble(args, "cameraChromaKeyStrength", 0.4);
  if (const auto argb = ReadOptionalInt(args, "cameraChromaKeyColorArgb")) {
    c.has_chroma_color = true;
    c.chroma_argb = static_cast<std::uint32_t>(*argb);
  }
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
// The `camera` block is emitted from the recording's persisted `editorSeed`
// (BuildScreenMetaJson writes it at record-stop; ParseScreenMetaJson reads it
// back into RecordingMetadata::editor_seed) so post-processing opens camera-on
// with the recorded settings, matching macOS. Bundles recorded before editorSeed
// landed have no seed, so the key is omitted and Dart's
// `RecordingSceneInfo.fromMap` treats a missing key and a `null` identically
// (`raw['camera'] is Map` → false) — a hidden camera, the prior behavior.
// ---------------------------------------------------------------------

flutter::EncodableMap BuildCameraExportCapabilities() {
  // These flags gate camera-overlay *export styling* in the Dart editor. The
  // slice plan flips them on as each lands:
  //   * 9.4 → shapeMask + cornerRadius (the basic circle / rounded bubble) ✅
  //   * 9.5 → border + shadow ✅
  //   * 9.7 → chromaKey ✅
  // Phase 9.4 composites the camera as a masked circle / rounded-rect / square
  // bubble; Phase 9.5 adds mirror, opacity, a stroked border, and a blurred drop
  // shadow; Phase 9.7 adds a Direct2D chroma key (and export-only intro/outro
  // animations, which are not gated by this map). So shapeMask + cornerRadius +
  // border + shadow + chromaKey are all true. (mirror / opacity are always-on
  // transforms, not gated by this map.) (Camera *device selection* readiness is a
  // separate concern, surfaced via getVideoSources / setVideoSource + the
  // camera-readiness check, not through this export-styling capabilities map.)
  // The Dart parser defaults a missing key to true, so we emit every key
  // explicitly.
  return flutter::EncodableMap{
      {flutter::EncodableValue("shapeMask"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("cornerRadius"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("border"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("shadow"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("chromaKey"), flutter::EncodableValue(true)},
  };
}

// Phase 5.2: translate a parsed editorSeed into the scene-info `camera` block
// Dart's CameraCompositionState.fromMap consumes. Keys are UN-prefixed and four
// are renamed vs the on-disk `camera*` keys (cameraShadow→shadowPreset,
// cameraNormalizedCenter→normalizedCanvasCenter, cameraBorderColorArgb→
// borderColorArgb, cameraChromaKeyColorArgb→chromaKeyColorArgb) — this mirrors
// macOS PreviewSceneResolver.cameraCompositionParamsMap exactly. ARGB values go
// out as int64 so 0xFFFFFFFF (4294967295) survives the bridge intact.
flutter::EncodableMap BuildCameraSceneBlock(
    const clingfy::capture::CameraEditorSeed& s) {
  flutter::EncodableMap m{
      {flutter::EncodableValue("visible"), flutter::EncodableValue(s.visible)},
      {flutter::EncodableValue("layoutPreset"),
       flutter::EncodableValue(s.layout_preset)},
      {flutter::EncodableValue("sizeFactor"),
       flutter::EncodableValue(s.size_factor)},
      {flutter::EncodableValue("shape"), flutter::EncodableValue(s.shape)},
      {flutter::EncodableValue("cornerRadius"),
       flutter::EncodableValue(s.corner_radius)},
      {flutter::EncodableValue("opacity"),
       flutter::EncodableValue(s.opacity)},
      {flutter::EncodableValue("mirror"), flutter::EncodableValue(s.mirror)},
      {flutter::EncodableValue("contentMode"),
       flutter::EncodableValue(s.content_mode)},
      {flutter::EncodableValue("zoomBehavior"),
       flutter::EncodableValue(s.zoom_behavior)},
      {flutter::EncodableValue("zoomScaleMultiplier"),
       flutter::EncodableValue(s.zoom_scale_multiplier)},
      {flutter::EncodableValue("introPreset"),
       flutter::EncodableValue(s.intro_preset)},
      {flutter::EncodableValue("outroPreset"),
       flutter::EncodableValue(s.outro_preset)},
      {flutter::EncodableValue("zoomEmphasisPreset"),
       flutter::EncodableValue(s.zoom_emphasis_preset)},
      {flutter::EncodableValue("introDurationMs"),
       flutter::EncodableValue(s.intro_duration_ms)},
      {flutter::EncodableValue("outroDurationMs"),
       flutter::EncodableValue(s.outro_duration_ms)},
      {flutter::EncodableValue("zoomEmphasisStrength"),
       flutter::EncodableValue(s.zoom_emphasis_strength)},
      {flutter::EncodableValue("borderWidth"),
       flutter::EncodableValue(s.border_width)},
      {flutter::EncodableValue("shadowPreset"),
       flutter::EncodableValue(s.shadow_preset)},
      {flutter::EncodableValue("chromaKeyEnabled"),
       flutter::EncodableValue(s.chroma_key_enabled)},
      {flutter::EncodableValue("chromaKeyStrength"),
       flutter::EncodableValue(s.chroma_key_strength)},
  };
  if (s.normalized_center_x.has_value() && s.normalized_center_y.has_value()) {
    m[flutter::EncodableValue("normalizedCanvasCenter")] =
        flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("x"),
             flutter::EncodableValue(*s.normalized_center_x)},
            {flutter::EncodableValue("y"),
             flutter::EncodableValue(*s.normalized_center_y)},
        });
  }
  if (s.border_color_argb.has_value()) {
    m[flutter::EncodableValue("borderColorArgb")] = flutter::EncodableValue(
        static_cast<std::int64_t>(*s.border_color_argb));
  }
  if (s.chroma_key_color_argb.has_value()) {
    m[flutter::EncodableValue("chromaKeyColorArgb")] = flutter::EncodableValue(
        static_cast<std::int64_t>(*s.chroma_key_color_argb));
  }
  return m;
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
    case ReadError::kProjectNotOpenable:
      return "PROJECT_STATUS_NOT_OPENABLE";
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
        error::kSceneInputMissing,
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
  // Phase 5.2: surface the persisted editorSeed as the `camera` block so
  // post-processing opens camera-on with the recorded settings (macOS parity).
  // Absent on pre-editorSeed Windows bundles (empty optional) → key omitted,
  // Dart falls back to a hidden camera — the prior behavior, so old recordings
  // still open unchanged.
  if (project.metadata.has_value() &&
      project.metadata->editor_seed.has_value()) {
    out[flutter::EncodableValue("camera")] = flutter::EncodableValue(
        BuildCameraSceneBlock(*project.metadata->editor_seed));
  }
  // Audio separation (D10): audio-presence keys so the post-processing
  // sidebar can gate the gain/volume controls on what the RECORDING
  // contains instead of the LIVE device selection. Separated recordings
  // ride the SAME decode probe preview/export use; legacy (premix-only)
  // recordings fall back to the capture-time truth in screen.meta.json —
  // their whole-track gain/volume works whenever the premix carried audio,
  // so sidecar-less must NOT read as "no audio" (that would disable
  // sliders that work). No metadata either → keys omitted → Dart keeps its
  // legacy device-selection gate (also the macOS shape today).
  const bool mic_sidecar_ok =
      project.mic_audio_path.has_value() &&
      clingfy::capture::export_::ProbeDecodableAudio(*project.mic_audio_path);
  const bool system_sidecar_ok =
      project.system_audio_path.has_value() &&
      clingfy::capture::export_::ProbeDecodableAudio(
          *project.system_audio_path);
  // `micGainApplies` names what the GAIN/NORMALIZE controls need: on a
  // separated recording they are mic-only (inert without a decodable mic
  // sidecar — D8/D9); on a legacy Windows premix they are whole-track and
  // work whenever the premix carried ANY audio.
  if (mic_sidecar_ok || system_sidecar_ok) {
    out[flutter::EncodableValue("hasMicAudio")] =
        flutter::EncodableValue(mic_sidecar_ok);
    out[flutter::EncodableValue("hasSystemAudio")] =
        flutter::EncodableValue(system_sidecar_ok);
    out[flutter::EncodableValue("micGainApplies")] =
        flutter::EncodableValue(mic_sidecar_ok);
  } else if (project.metadata.has_value() &&
             project.metadata->platform == "windows") {
    // The metadata fallback reads WINDOWS capture truth. A macOS bundle's
    // screen.meta.json has a different shape (its micActive/samples fields
    // parse to defaults here), so gating on it would report false/false
    // and disable sliders that work on the mac premix — omit the keys
    // instead (Dart's legacy device gate takes over, today's behavior).
    const bool premix_has_samples =
        project.metadata->audio_samples_written > 0;
    out[flutter::EncodableValue("hasMicAudio")] = flutter::EncodableValue(
        premix_has_samples && project.metadata->mic_active);
    out[flutter::EncodableValue("hasSystemAudio")] = flutter::EncodableValue(
        premix_has_samples && project.metadata->loopback_active);
    out[flutter::EncodableValue("micGainApplies")] =
        flutter::EncodableValue(premix_has_samples);
  }
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
    // Phase 10.4: reader errors also go over the native→Dart log bridge —
    // OutputDebugStringW alone is lost in installed builds.
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Preview", std::string("previewOpen reader failed: ") +
                       ReadErrorVariantName(read.error) + " — " +
                       read.message);
    // Match the macOS PreviewSceneResolver error code + message
    // shape; details echoes the projectPath so the Dart layer can
    // surface "<path> could not be opened" without re-deriving it.
    result->Error(
        error::kPreviewInputMissing,
        "Recording project not found. It may have been moved or deleted.",
        flutter::EncodableValue(project_path_utf8));
    return;
  }

  clingfy::preview::OpenArgs open_args{};
  open_args.session_id = session_id;
  open_args.project_path = project_path_utf8;
  open_args.video_path = read.project->screen_path;
  // Polish: the recording's natural size from screen.meta.json sizes the
  // shared texture to the video's aspect (no double letterbox on non-16:9
  // recordings; the camera canvas matches the export's auto layout).
  if (read.project->metadata.has_value()) {
    open_args.video_width_hint =
        static_cast<int>(read.project->metadata->width);
    open_args.video_height_hint =
        static_cast<int>(read.project->metadata->height);
  }
  if (read.project->cursor_path.has_value()) {
    open_args.cursor_path = *read.project->cursor_path;
  }
  // Audio separation (D9): hand the existence-gated sidecar paths to the
  // engine, which runs the decode probe once at Open. Absent → empty →
  // the edited preview keeps the premix whole-track path.
  if (read.project->mic_audio_path.has_value()) {
    open_args.mic_audio_path = *read.project->mic_audio_path;
  }
  if (read.project->system_audio_path.has_value()) {
    open_args.system_audio_path = *read.project->system_audio_path;
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
    // Phase 10.4: engine-side failures (D3D/D2D/texture/MediaPlayer setup)
    // get their OWN code. They used to collapse into PREVIEW_INPUT_MISSING,
    // so a GPU failure rendered as "recording files missing" — wrong
    // diagnosis, wrong user action. Also surfaced over the log bridge: the
    // engine's own logging goes only to its side file.
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Preview", "previewOpen engine failed: " + r.error);
    result->Error(
        error::kPreviewOpenError,
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
  // Engine state carries 0 until the first decoded frame; seed the natural
  // size from screen.meta.json so Dart sees real dimensions at open time.
  const int video_w = r.video_width > 0 ? r.video_width
                                        : open_args.video_width_hint;
  const int video_h = r.video_height > 0 ? r.video_height
                                         : open_args.video_height_hint;
  out[flutter::EncodableValue("videoWidth")] = flutter::EncodableValue(video_w);
  out[flutter::EncodableValue("videoHeight")] =
      flutter::EncodableValue(video_h);
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

// Editing port (color): pushes the Dart color grade to the live preview.
// Parsed by the shared color_grade_args helper (the same parser the export
// router uses — one wire shape, one parser). Stale-session calls are dropped
// engine-side; a paused preview is nudged to recomposite immediately.
// Always replies null (matches the void Dart contract).
void HandlePreviewSetColorGrade(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    const std::string session_id = ReadString(*args, "sessionId");
    PreviewEngine::Instance()->SetColorGrade(
        session_id, clingfy::bridge::ReadColorGradeArg(*args));
  }
  reply::Null(*result);
}

// Editing port (clips, step 4-1): pushes the Dart clip list to the live
// preview. Parsed by the shared clip_args helper (the same wire shape the
// export router uses — one parser, per the color_grade precedent). Stale-session
// calls are dropped engine-side. Always replies null (the void Dart contract).
void HandlePreviewSetClips(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    const std::string session_id = ReadString(*args, "sessionId");
    PreviewEngine::Instance()->SetClips(session_id,
                                        clingfy::bridge::ReadClipRangesArg(*args));
  }
  reply::Null(*result);
}

// Editing port (audio, step 4-7d): the live preview mix. `updateAudioPreview`
// is the method Dart actually sends (NativeBridge.setAudioMix, keys
// gain/volume, debounced 150 ms during slider drags); the preview* names are
// the macOS dispatch aliases (keys audioGainDb/audioVolumePercent) — kept
// real and thin here, converging on PreviewEngine::SetAudioMix exactly like
// the three macOS handlers converge on its setAudioMix. Both key spellings
// are accepted on every method (macOS MainFlutterWindow parity).
void HandleUpdateAudioPreview(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    const double gain =
        ReadDouble(*args, "gain", ReadDouble(*args, "audioGainDb", 0.0));
    const double volume = ReadDouble(
        *args, "volume", ReadDouble(*args, "audioVolumePercent", 100.0));
    PreviewEngine::Instance()->SetAudioMix(ReadString(*args, "sessionId"),
                                           gain, volume);
  }
  reply::Null(*result);
}

void HandlePreviewSetAudioGainDb(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    // Gain-only alias: volume stays at unity (macOS parity).
    PreviewEngine::Instance()->SetAudioMix(
        ReadString(*args, "sessionId"), ReadDouble(*args, "audioGainDb", 0.0),
        100.0);
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
  // Voice cleanup (noise reduction) is macOS-only for now. The blocker is no
  // longer the audio layout — audio separation (slices A-C) gives Windows the
  // same `capture/mic.m4a` sidecar the macOS stage denoises — it is that the
  // RNNoise engine is not built here: both CMake projects declare LANGUAGES CXX
  // only, so vendoring its C sources needs `enable_language(C)` or a separate C
  // target first. Registered as a no-op so the additive Flutter call succeeds;
  // the UI hides the control until the engine lands. The port's insertion point
  // is the mic pump, before ResolveAudioGainStages in export_pipeline.
  table["previewSetVoiceCleanup"] = &HandleNoopSetter;
  // Color grade (editing port step 2): live on Windows — the same D2D color
  // chain the export bakes with (Graphics/color_grade_effect), applied to
  // the preview video by preview_compositor. Video-only, like macOS preview.
  table["previewSetColorGrade"] = &HandlePreviewSetColorGrade;
  // Clip split/cut/trim/arrange (editing port step 4-1): the clip list is now
  // STORED on the preview session (SetClips). The stitched decode that plays
  // through cuts/reorder lands in the following slices; a passthrough list keeps
  // the preview byte-identical to today.
  table["previewSetClips"] = &HandlePreviewSetClips;
  // Audio mix (editing port step 4-7d): live on Windows — gain+volume on the
  // edited-session renderer, volume on the passthrough MediaPlayer.
  // `updateAudioPreview` registers HERE (it is a preview method; it was a
  // devices_router no-op until this slice).
  table["updateAudioPreview"] = &HandleUpdateAudioPreview;
  table["previewSetAudioMix"] = &HandleUpdateAudioPreview;
  table["previewSetAudioGainDb"] = &HandlePreviewSetAudioGainDb;

  table["previewGetZoomCapabilities"] = &HandleGetZoomCapabilities;
  table["previewGetCursorSamples"] = &HandleGetCursorSamples;
  table["previewGetSourceDimensions"] = &HandleGetSourceDimensions;

  // Step 5.2: real getRecordingSceneInfo backed by RecordingProjectReader.
  // Was a Phase 1 stub in Bridge/Routers/export_router.cpp until 5.2.
  table["getRecordingSceneInfo"] = &HandleGetRecordingSceneInfo;
}

}  // namespace clingfy::bridge::routers::preview
