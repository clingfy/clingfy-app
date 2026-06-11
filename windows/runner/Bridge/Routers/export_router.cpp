#include "Bridge/Routers/export_router.h"

#include <cstdint>
#include <exception>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <system_error>
#include <thread>
#include <utility>

#include "Bridge/export_progress_publisher.h"
#include "Bridge/native_error_codes.h"
#include "Bridge/native_log_publisher.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Bridge/result_helpers.h"
#include "Capture/Cursor/cursor_sidecar_reader.h"
#include "Capture/Export/export_passthrough.h"
#include "Capture/Export/export_session.h"
#include "Capture/Zoom/zoom_timeline_builder.h"
#include "Capture/recording_project_reader.h"
#include "Services/shell_reveal.h"
#include "preview/preview_engine.h"

namespace clingfy::bridge::routers::export_ {

namespace {

void HandleNotImplemented(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::NotImplemented(*result, call.method_name());
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
  // back gracefully. Manual zoom editing is hidden on Windows (Phase 10.3)
  // until real persistence lands.
  reply::Bool(*result, false);
}

// ---- Phase 6 / Slice 1-5A ---------------------------------------------------
// `exportVideo` and `processVideo` are off the NotImplemented stub.
//   - exportVideo: writes to a Dart-chosen destination directory + filename in
//     the requested container (.mp4 or .mov, Slice 5A). layout=auto &
//     resolution=auto with no padding / corner radius / audio change take the
//     byte-for-byte copy fast-path; anything else routes through the
//     decode → composite → re-encode pipeline (`export_pipeline.h`) with the
//     Slice 3 styling, Slice 4 audio, and the Slice 5A bitrate. In production
//     the export runs on a worker thread (so the platform thread can receive
//     cancelExport + emit `updateExportProgress`); the reply is marshaled back
//     via the platform-thread dispatcher. Every outcome — success, failure,
//     and cancel — completes the MethodResult exactly once.
//   - cancelExport: signals the in-flight export to stop and replies null
//     immediately; the export then resolves its own future as a cancellation.
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

// ---- getZoomSegments (Phase 10.3) -------------------------------------------
//
// Returns the SAME auto-zoom segment list the export will render, computed
// the same way ExportPassthrough/ZoomExportController do it: project bundle
// → cursor sidecar → BuildZoomSegments over its samples + clicks. This is
// what makes the editor's zoom track honest on Windows — before this, the
// track was empty while the default export auto-zoomed anyway.
//
// Reply shape matches macOS ZoomQueryService exactly:
//   [{id: "auto_<i>", startMs: int, endMs: int, source: "auto"}]
// Every failure (missing project, no sidecar, parse error) replies [] —
// the macOS contract for "nothing to show".
//
// duration_ms is passed as 0, which derives the timeline end from the last
// sidecar event (zoom_timeline_builder.cpp): start times and interior end
// times are identical to the export's; only a final still-active segment's
// endMs can differ from the export's MF-duration-clamped value.
void HandleGetZoomSegments(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string project_path;
  if (const auto* args = AsMap(call.arguments())) {
    project_path = ReadString(*args, "projectPath");
  }
  if (project_path.empty()) {
    reply::EmptyList(*result);
    return;
  }

  // The channel string is UTF-8; fs::path(std::string) would decode it
  // with the legacy ACP (this exe does not opt into the UTF-8 code page),
  // silently failing for non-ASCII user names. Use the same CP_UTF8
  // conversion every other ReadRecordingProject call site uses.
  auto read = clingfy::capture::ReadRecordingProject(
      clingfy::storage::Utf8ToWide(project_path));
  if (read.error != clingfy::capture::ReadError::kNone ||
      !read.project.has_value()) {
    reply::EmptyList(*result);
    return;
  }

  // Same sidecar resolution as export_passthrough: prefer the manifest's
  // cursor path, else the conventional sibling of the screen video.
  std::filesystem::path sidecar_path;
  if (read.project->cursor_path.has_value()) {
    sidecar_path = std::filesystem::path(*read.project->cursor_path);
  } else {
    sidecar_path = std::filesystem::path(read.project->screen_path)
                       .parent_path() /
                   L"cursor.jsonl";
  }
  std::error_code ec;
  if (!std::filesystem::exists(sidecar_path, ec)) {
    reply::EmptyList(*result);
    return;
  }
  std::ifstream file(sidecar_path, std::ios::in | std::ios::binary);
  if (!file.is_open()) {
    reply::EmptyList(*result);
    return;
  }
  std::stringstream buffer;
  buffer << file.rdbuf();
  const auto sidecar =
      clingfy::capture::ParseCursorSidecar(buffer.str());
  if (!sidecar.has_value()) {
    reply::EmptyList(*result);
    return;
  }

  const auto segments = clingfy::capture::BuildZoomSegments(
      sidecar->samples, sidecar->clicks, /*duration_ms=*/0);
  flutter::EncodableList out;
  out.reserve(segments.size());
  for (size_t i = 0; i < segments.size(); ++i) {
    out.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("id"),
         flutter::EncodableValue("auto_" + std::to_string(i))},
        {flutter::EncodableValue("startMs"),
         flutter::EncodableValue(static_cast<std::int64_t>(
             segments[i].start_ms))},
        {flutter::EncodableValue("endMs"),
         flutter::EncodableValue(static_cast<std::int64_t>(
             segments[i].end_ms))},
        {flutter::EncodableValue("source"), flutter::EncodableValue("auto")},
    }));
  }
  reply::List(*result, std::move(out));
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
    // Slice 5A. Bitrate is a preset string resolved against the output size;
    // format selects the container (.mp4 vs .mov).
    input.bitrate = ReadString(*args, "bitrate");
    // Phase 8.2: cursor rendering. showCursor (default true) + cursorSize
    // (0.5..3.0, default 1.5) match the Dart export args. When showCursor is on
    // and the recording has a cursor sidecar, the export renders the cursor
    // (which forces the composition path — a byte-copy can't draw it).
    input.show_cursor = ReadBool(*args, "showCursor", true);
    input.cursor_size = ReadDouble(*args, "cursorSize", 1.5);
    // Phase 8.3: smart zoom. zoomEffectEnabled (default true) + zoomFactor
    // (1.0..3.0, default 1.5) match the Dart export args. Auto-zoom is generated
    // natively from the cursor sidecar; manual zoomSegments are not consumed yet.
    input.zoom_effect_enabled = ReadBool(*args, "zoomEffectEnabled", true);
    input.zoom_factor = ReadDouble(*args, "zoomFactor", 1.5);
    // Phase 9.4: camera bubble. The Dart side spreads CameraCompositionState
    // .toMap() into the export args (cameraVisible, cameraNormalizedCenter {x,y}
    // or null, cameraLayoutPreset, cameraSizeFactor, cameraShape,
    // cameraCornerRadius, cameraContentMode). Whether the camera is actually
    // drawn also depends on the project assets + camera.meta.json, resolved in
    // ExportPassthroughCopy. Styling we don't support yet (mirror / opacity /
    // border / shadow / chroma) is accepted-but-ignored per the capabilities map.
    input.camera_visible = ReadBool(*args, "cameraVisible", false);
    input.camera_layout_preset = ReadString(*args, "cameraLayoutPreset");
    input.camera_size_factor = ReadDouble(*args, "cameraSizeFactor", 0.18);
    input.camera_shape = ReadString(*args, "cameraShape");
    input.camera_corner_radius = ReadDouble(*args, "cameraCornerRadius", 0.0);
    input.camera_content_mode = ReadString(*args, "cameraContentMode");
    // Phase 9.5 styling. cameraBorderColorArgb is a nullable ARGB int (null →
    // no border even if width > 0); the others have identity-ish defaults.
    input.camera_mirror = ReadBool(*args, "cameraMirror", false);
    input.camera_opacity = ReadDouble(*args, "cameraOpacity", 1.0);
    input.camera_border_width = ReadDouble(*args, "cameraBorderWidth", 0.0);
    input.camera_border_color_argb =
        ReadOptionalInt(*args, "cameraBorderColorArgb");
    input.camera_shadow_preset =
        static_cast<int>(ReadDouble(*args, "cameraShadowPreset", 0.0));
    // Phase 9.7 chroma key + intro/outro animation. chromaKeyColorArgb is a
    // nullable ARGB int (null → default green); strength is the keying tolerance.
    // The intro/outro preset strings parse natively (unknown → static bubble).
    input.camera_chroma_enabled = ReadBool(*args, "cameraChromaKeyEnabled", false);
    input.camera_chroma_strength =
        ReadDouble(*args, "cameraChromaKeyStrength", 0.4);
    input.camera_chroma_color_argb =
        ReadOptionalInt(*args, "cameraChromaKeyColorArgb");
    input.camera_intro_preset = ReadString(*args, "cameraIntroPreset");
    input.camera_outro_preset = ReadString(*args, "cameraOutroPreset");
    input.camera_intro_duration_ms =
        static_cast<int>(ReadDouble(*args, "cameraIntroDurationMs", 0.0));
    input.camera_outro_duration_ms =
        static_cast<int>(ReadDouble(*args, "cameraOutroDurationMs", 0.0));
    // cameraNormalizedCenter is a nested {x,y} map (or null when the bubble is
    // auto-placed by preset). Present → manual placement.
    if (const auto it = args->find(flutter::EncodableValue(
            "cameraNormalizedCenter"));
        it != args->end()) {
      if (const auto* center = std::get_if<flutter::EncodableMap>(&it->second)) {
        input.camera_has_center = true;
        input.camera_center_x = ReadDouble(*center, "x", 0.0);
        input.camera_center_y = ReadDouble(*center, "y", 0.0);
      }
    }
  }

  // Defensive: refuse a second concurrent export (Dart's _isExporting guards
  // the UI, but native must not run two encoders at once). BeginExport also
  // clears any stale cancel flag from a prior run.
  if (!clingfy::capture::export_::ExportSession::Instance().BeginExport()) {
    result->Error(error::kBadArgs,
                  "exportVideo: an export is already in progress.",
                  flutter::EncodableValue(input.project_path));
    return;
  }

  // Stateless callbacks targeting process singletons — safe to copy into the
  // worker thread and the export pipeline.
  auto on_progress = [](double fraction) {
    ExportProgressPublisher::Instance().EmitProgress(fraction);
  };
  auto is_cancelled = [] {
    return clingfy::capture::export_::ExportSession::Instance().IsCancelled();
  };

  // Without the platform-thread dispatcher (tests / cold start) run the export
  // synchronously so the reply is observable in-line. In production run it on a
  // worker thread — otherwise the blocked platform thread could never receive
  // cancelExport — and marshal the reply back via the dispatcher.
  if (!PlatformThreadDispatcher::Instance().is_initialized()) {
    // Same exception mapping as the worker path below. The MethodRouter
    // dispatch barrier would catch a throw here too, but it cannot know to
    // call EndExport() — without this catch the session would stay
    // "running" forever and every later export would be rejected.
    clingfy::capture::export_::PassthroughResult outcome;
    try {
      outcome = clingfy::capture::export_::ExportPassthroughCopy(
          input, on_progress, is_cancelled);
    } catch (const std::exception& e) {
      outcome.error =
          clingfy::capture::export_::PassthroughError::kRenderFailed;
      outcome.message =
          std::string("Unhandled exception during export: ") + e.what();
    } catch (...) {
      outcome.error =
          clingfy::capture::export_::PassthroughError::kRenderFailed;
      outcome.message = "Unhandled exception during export: unknown exception.";
    }
    clingfy::capture::export_::ExportSession::Instance().EndExport();
    ReplyForExportOutcome(*result, outcome, input.project_path,
                          input.directory_override);
    return;
  }

  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_result(
      std::move(result));
  std::thread([input, shared_result, on_progress, is_cancelled]() {
    // Phase 10.4 worker barrier: an exception escaping a detached thread
    // calls std::terminate and kills the whole process — and this thread is
    // OUTSIDE the MethodRouter dispatch barrier (which only covers the
    // synchronous handler call). Convert any throw into a normal failed
    // outcome so the shared reply path below still resolves the Dart future
    // exactly once (EXPORT_ERROR via ReplyForExportOutcome, which also emits
    // the native log line).
    clingfy::capture::export_::PassthroughResult outcome;
    try {
      outcome = clingfy::capture::export_::ExportPassthroughCopy(
          input, on_progress, is_cancelled);
    } catch (const std::exception& e) {
      outcome.error = clingfy::capture::export_::PassthroughError::kRenderFailed;
      outcome.message =
          std::string("Unhandled exception during export: ") + e.what();
    } catch (...) {
      outcome.error = clingfy::capture::export_::PassthroughError::kRenderFailed;
      outcome.message = "Unhandled exception during export: unknown exception.";
    }
    clingfy::capture::export_::ExportSession::Instance().EndExport();
    // Reply on the platform thread. shared_result keeps the MethodResult alive
    // until the reply runs (never dropped -> never a hung Dart future).
    PlatformThreadDispatcher::Instance().Post(
        [shared_result, outcome, project_path = input.project_path,
         directory_override = input.directory_override]() {
          ReplyForExportOutcome(*shared_result, outcome, project_path,
                                directory_override);
        });
  }).detach();
}

void HandleCancelExport(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Signal the in-flight export to stop at its next cancel check; it replies to
  // its own exportVideo future with a cancellation. Reply immediately and
  // independently (macOS does `result(nil)`).
  clingfy::capture::export_::ExportSession::Instance().RequestCancel();
  reply::Null(*result);
}

void HandleProcessVideo(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Phase 9.6: the Windows preview does NOT pre-render a composited file, so we
  // still return null (Dart keeps using the live preview texture). But the call
  // carries the camera composition (visible / placement / shape / 9.5 styling),
  // which we forward to the PreviewEngine so the inline preview draws the bubble
  // live — WYSIWYG with the export. This fires at preview open and on every
  // layout/styling change; placement drags additionally use
  // previewSetCameraPlacement. Stale-session calls are dropped engine-side.
  if (const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments())) {
    clingfy::preview::PreviewCameraComposition c;
    c.visible = ReadBool(*args, "cameraVisible", false);
    c.layout_preset = ReadString(*args, "cameraLayoutPreset");
    c.size_factor = ReadDouble(*args, "cameraSizeFactor", 0.18);
    c.shape = ReadString(*args, "cameraShape");
    c.corner_radius = ReadDouble(*args, "cameraCornerRadius", 0.0);
    c.content_mode = ReadString(*args, "cameraContentMode");
    c.mirror = ReadBool(*args, "cameraMirror", false);
    c.opacity = ReadDouble(*args, "cameraOpacity", 1.0);
    c.border_width = ReadDouble(*args, "cameraBorderWidth", 0.0);
    if (const auto argb = ReadOptionalInt(*args, "cameraBorderColorArgb")) {
      c.has_border_color = true;
      c.border_argb = static_cast<std::uint32_t>(*argb);
    }
    c.shadow_preset =
        static_cast<int>(ReadDouble(*args, "cameraShadowPreset", 0.0));
    // Phase 9.7 chroma key — kept in sync with preview_router's
    // ReadCameraComposition so a chroma edit (which arrives via processVideo)
    // shows in the inline preview, WYSIWYG with the export.
    c.chroma_enabled = ReadBool(*args, "cameraChromaKeyEnabled", false);
    c.chroma_strength = ReadDouble(*args, "cameraChromaKeyStrength", 0.4);
    if (const auto argb = ReadOptionalInt(*args, "cameraChromaKeyColorArgb")) {
      c.has_chroma_color = true;
      c.chroma_argb = static_cast<std::uint32_t>(*argb);
    }
    if (const auto it =
            args->find(flutter::EncodableValue("cameraNormalizedCenter"));
        it != args->end()) {
      if (const auto* center =
              std::get_if<flutter::EncodableMap>(&it->second)) {
        c.has_center = true;
        c.center_x = ReadDouble(*center, "x", 0.0);
        c.center_y = ReadDouble(*center, "y", 0.0);
      }
    }
    clingfy::preview::PreviewEngine::Instance()->SetCameraComposition(
        ReadString(*args, "sessionId"), c);
  }
  reply::Null(*result);
}

}  // namespace

// Complete the exportVideo MethodResult for a finished export. Pulled out so
// the SAME mapping runs whether the export ran synchronously (tests) or on a
// worker thread (production, replied via PlatformThreadDispatcher::Post).
// Declared in export_router.h so unit tests can pin the per-outcome contract.
void ReplyForExportOutcome(
    flutter::MethodResult<flutter::EncodableValue>& result,
    const clingfy::capture::export_::PassthroughResult& outcome,
    const std::string& project_path, const std::string& directory_override) {
  using clingfy::capture::export_::FormatBytesForUser;
  using clingfy::capture::export_::PassthroughError;
  // Phase 10.4: every failed export emits ONE native log line so beta
  // reports show the failure (no-op when no channel is attached — tests).
  // Errors become Sentry exceptions via Dart's telemetry sink; a user cancel
  // is a Warn, not a failure.
  const auto log_failure = [](const char* code, const std::string& message) {
    NativeLogPublisher::Instance().Error("Export",
                                         std::string(code) + ": " + message);
  };
  switch (outcome.error) {
    case PassthroughError::kNone:
      reply::String(result, outcome.output_path);
      return;
    case PassthroughError::kInputMissing:
      log_failure(error::kExportInputMissing, outcome.message);
      result.Error(error::kExportInputMissing, outcome.message,
                   flutter::EncodableValue(project_path));
      return;
    case PassthroughError::kNoDestination:
      log_failure(error::kBadArgs, outcome.message);
      result.Error(error::kBadArgs, outcome.message,
                   flutter::EncodableValue(directory_override));
      return;
    case PassthroughError::kDiskFull: {
      // Phase 10.4: stable EXPORT_DISK_FULL code with a details payload
      // shaped EXACTLY like macOS ExportPrep.flutterExportFailure emits —
      // {stage, reason, context} where context carries the byte counts.
      // Dart's ExportDiskFullMessage re-renders a localized message from
      // context.{estimatedRequiredTemp,availableTemp,shortfallTemp}Formatted
      // and falls back to `message` when those are absent (the mid-write
      // classification, which has no preflight estimate).
      const std::int64_t required = outcome.disk_required_bytes;
      const std::int64_t available = outcome.disk_available_bytes;
      flutter::EncodableMap context{
          {flutter::EncodableValue("tempPath"),
           flutter::EncodableValue(outcome.disk_checked_path)},
      };
      if (required >= 0 && available >= 0) {
        const std::int64_t shortfall =
            required > available ? required - available : 0;
        context[flutter::EncodableValue("availableTempBytes")] =
            flutter::EncodableValue(available);
        context[flutter::EncodableValue("estimatedRequiredTempBytes")] =
            flutter::EncodableValue(required);
        context[flutter::EncodableValue("shortfallTempBytes")] =
            flutter::EncodableValue(shortfall);
        context[flutter::EncodableValue("availableTempFormatted")] =
            flutter::EncodableValue(FormatBytesForUser(available));
        context[flutter::EncodableValue("estimatedRequiredTempFormatted")] =
            flutter::EncodableValue(FormatBytesForUser(required));
        context[flutter::EncodableValue("shortfallTempFormatted")] =
            flutter::EncodableValue(FormatBytesForUser(shortfall));
      }
      flutter::EncodableMap details{
          {flutter::EncodableValue("stage"),
           flutter::EncodableValue(std::string(
               required >= 0 ? "export_preflight" : "export_write"))},
          {flutter::EncodableValue("reason"),
           flutter::EncodableValue(outcome.message)},
          {flutter::EncodableValue("context"),
           flutter::EncodableValue(std::move(context))},
      };
      log_failure(error::kExportDiskFull, outcome.message);
      result.Error(error::kExportDiskFull, outcome.message,
                   flutter::EncodableValue(std::move(details)));
      return;
    }
    case PassthroughError::kCancelled:
      // Phase 10.4: a clean user cancel replies with the stable
      // EXPORT_CANCELLED code (Dart classifies by code, not by sniffing a
      // "cancelled" message out of EXPORT_ERROR). The message still contains
      // "cancelled" so an older Dart message-classifier also reads it as a
      // cancel.
      NativeLogPublisher::Instance().Warn(
          "Export",
          std::string(error::kExportCancelled) + ": Export cancelled.");
      result.Error(error::kExportCancelled, "Export cancelled.",
                   flutter::EncodableValue(project_path));
      return;
    case PassthroughError::kCopyFailed:
    case PassthroughError::kRenderFailed:
      log_failure(error::kExportError, outcome.message);
      result.Error(error::kExportError, outcome.message,
                   flutter::EncodableValue(project_path));
      return;
    default: {
      // Every PassthroughError MUST complete the MethodResult. An un-answered
      // result is destroyed silently and the Dart `exportVideo` future never
      // resolves — the export UI hangs with no error. This default guards any
      // future enum value (MSVC's C4061/C4062 do not fire at /W4).
      const std::string message = outcome.message.empty()
                                      ? "exportVideo: unknown export failure"
                                      : outcome.message;
      log_failure(error::kExportError, message);
      result.Error(error::kExportError, message,
                   flutter::EncodableValue(project_path));
      return;
    }
  }
}

void RegisterHandlers(HandlerTable& table) {
  table["exportVideo"] = &HandleExportVideo;
  table["processVideo"] = &HandleProcessVideo;
  table["cancelExport"] = &HandleCancelExport;

  // `getRecordingSceneInfo` was a Phase 1 stub here; Step 5.2 moved it
  // into `Bridge/Routers/preview_router.cpp` where it now reads the
  // .clingfyproj manifest via `clingfy::capture::RecordingProjectReader`
  // and returns the macOS-shaped map.

  table["getZoomSegments"] = &HandleGetZoomSegments;
  table["getManualZoomSegments"] = &HandleEmptyList;
  table["saveManualZoomSegments"] = &HandleSaveManualZoomSegments;
}

}  // namespace clingfy::bridge::routers::export_
