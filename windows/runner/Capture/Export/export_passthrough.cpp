#include "Capture/Export/export_passthrough.h"

#include <windows.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <functional>
#include <optional>
#include <sstream>
#include <string>
#include <system_error>

#include "Capture/Camera/camera_meta.h"
#include "Capture/Export/export_audio.h"
#include "Capture/Export/export_format.h"
#include "Capture/Export/export_geometry.h"
#include "Capture/Export/export_pipeline.h"
#include "Capture/recording_project_reader.h"
#include "Services/save_folder.h"

namespace clingfy::capture::export_ {

namespace {

namespace fs = std::filesystem;

// Trim leading + trailing whitespace. Matches what a typical save-as
// dialog would normalize but Dart side passes the raw user input.
std::string Trim(std::string value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) {
    return {};
  }
  const auto last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}

// Strip the last `.ext` from a filename stem, if any. The user may have
// typed "MyRecording.mp4" into the dialog; Slice 1 always writes a MOV
// container so we drop whatever extension was supplied and re-add .mov
// downstream. Multi-dot stems ("first.draft") keep all but the last.
std::string StripExtension(const std::string& filename) {
  const auto dot = filename.find_last_of('.');
  // Conservative: only treat dot as an extension separator if there are
  // 1-5 non-slash chars after it. Avoids stripping "foo.bar.baz" → "foo".
  if (dot == std::string::npos) {
    return filename;
  }
  const auto tail = filename.substr(dot + 1);
  if (tail.empty() || tail.size() > 5) {
    return filename;
  }
  if (tail.find_first_of("/\\") != std::string::npos) {
    return filename;
  }
  return filename.substr(0, dot);
}

// Replace any character Windows forbids in a filename with an underscore.
// Mirrors what the encoder_output_path's SanitizeSessionId does but
// keeps spaces (filenames are user-visible; "My Recording" should stay
// "My Recording").
std::string SanitizeFilename(const std::string& stem) {
  static constexpr const char* kForbidden = "\\/:*?\"<>|";
  std::string out = stem;
  for (char& ch : out) {
    if (std::strchr(kForbidden, ch) != nullptr) {
      ch = '_';
    }
  }
  return out;
}

// Pick a non-colliding filename. If `<dir>\<stem>.mov` already exists,
// try `<dir>\<stem> (1).mov`, `(2).mov`, etc. Mirrors the macOS
// `LetterboxExporter` collision-avoidance pattern so a user who
// exports the same recording twice gets two files instead of an
// overwrite. Caps at 999 attempts to avoid pathological loops.
fs::path UniqueDestination(const fs::path& dir, const std::string& stem,
                           const std::string& ext) {
  fs::path candidate = dir / (stem + ext);
  if (!fs::exists(candidate)) {
    return candidate;
  }
  for (int i = 1; i < 1000; ++i) {
    candidate = dir / (stem + " (" + std::to_string(i) + ")" + ext);
    if (!fs::exists(candidate)) {
      return candidate;
    }
  }
  // Pathological: 1000 collisions. Caller will surface the eventual
  // copy_file failure as kCopyFailed.
  return dir / (stem + " (overflow)" + ext);
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return {};
  }
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) {
    return {};
  }
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                         static_cast<int>(wide.size()), out.data(), needed,
                         nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return {};
  }
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) {
    return {};
  }
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                         static_cast<int>(utf8.size()), out.data(), needed);
  return out;
}

// Read a small text file (camera.meta.json) fully into a UTF-8 string. Returns
// nullopt when the file can't be opened. Binary mode so byte offsets in the JSON
// parser match the on-disk content exactly.
std::optional<std::string> ReadFileToString(const fs::path& path) {
  std::ifstream f(path, std::ios::in | std::ios::binary);
  if (!f.is_open()) {
    return std::nullopt;
  }
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

}  // namespace

bool ShouldCompositeCamera(bool camera_visible, bool has_camera_assets,
                           bool meta_parsed, bool preview_burned_in,
                           std::uint64_t frames_written) {
  return camera_visible && has_camera_assets && meta_parsed &&
         !preview_burned_in && frames_written > 0;
}

std::string ResolveExportDestination(const std::string& directory,
                                     const std::string& filename_stem,
                                     const std::string& format) {
  const std::string trimmed_dir = Trim(directory);
  const std::string trimmed_stem = Trim(filename_stem);

  std::string stem = StripExtension(trimmed_stem);
  stem = SanitizeFilename(stem);
  if (stem.empty()) {
    stem = "Untitled";
  }

  fs::path dir_path = fs::u8path(trimmed_dir);
  fs::path candidate =
      UniqueDestination(dir_path, stem, ResolveExportExtension(format));
  return candidate.u8string();
}

PassthroughResult ExportPassthroughCopy(
    const PassthroughInput& input, std::function<void(double)> on_progress,
    std::function<bool()> is_cancelled) {
  PassthroughResult out;

  // Slice 5A: honor a cancel that arrived before any work started.
  if (is_cancelled && is_cancelled()) {
    out.error = PassthroughError::kCancelled;
    out.message = "exportVideo: cancelled by user";
    return out;
  }

  const std::string project = Trim(input.project_path);
  if (project.empty()) {
    out.error = PassthroughError::kInputMissing;
    out.message = "exportVideo: projectPath is required but was empty.";
    return out;
  }

  std::string dir = Trim(input.directory_override);
  if (dir.empty()) {
    // No explicit destination: fall back to the default save folder,
    // created on demand. Mirrors macOS, where ExportEngine resolves the
    // SaveFolderStore (~/Movies/Clingfy) when directoryOverride is empty.
    const std::wstring fallback = clingfy::storage::DefaultSaveFolder();
    if (!fallback.empty() && clingfy::storage::EnsureDirectoryExists(fallback)) {
      dir = clingfy::storage::WideToUtf8(fallback);
    }
  }
  if (dir.empty()) {
    out.error = PassthroughError::kNoDestination;
    out.message =
        "exportVideo: no directoryOverride supplied and the default save "
        "folder could not be resolved or created.";
    return out;
  }

  // Resolve the source video path via the same reader the preview side
  // uses. Any project-bundle inconsistency surfaces here as a clean
  // EXPORT_INPUT_MISSING.
  const auto read = ReadRecordingProject(Utf8ToWide(project));
  if (read.error != ReadError::kNone || !read.project.has_value()) {
    out.error = PassthroughError::kInputMissing;
    out.message = "exportVideo: failed to read project bundle — " +
                  read.message;
    return out;
  }
  const fs::path source = fs::path(read.project->screen_path);

  // Phase 8.2: the cursor sidecar sits beside the screen video in the bundle.
  // The export renders the cursor when the user wants it AND the recording has a
  // sidecar — which forces the composition path below (a byte-copy can't draw
  // it). A missing sidecar (older recording / cursor-on fallback) simply renders
  // no cursor.
  //
  // The name is the sibling `cursor.jsonl` written by the project writer (kept in
  // sync with `recording_project_writer.cpp`'s manifest `cursorData` →
  // "capture/cursor.jsonl"). `screen_path` is `<root>/capture/screen.mov`, so its
  // parent is the `capture/` dir.
  const fs::path cursor_sidecar = source.parent_path() / "cursor.jsonl";
  std::error_code cursor_ec;
  const bool sidecar_exists = fs::exists(cursor_sidecar, cursor_ec);
  const bool wants_cursor_render = input.show_cursor && sidecar_exists;
  // Phase 8.3: smart zoom reads the same sidecar (clicks + cursor path).
  const bool wants_zoom = input.zoom_effect_enabled && sidecar_exists;
  const bool wants_sidecar = wants_cursor_render || wants_zoom;

  // Phase 9.4: resolve the camera bubble. The project reader only sets
  // camera_video_path/camera_metadata_path when BOTH exist on disk (present-
  // together), so a half-broken bundle never reaches here. We parse the metadata
  // for the startOffsetMs sync key + previewBurnedIn guard, then gate via
  // ShouldCompositeCamera. Any miss (no assets, unparseable meta, burned-in
  // preview, zero frames, or the user hid the camera) → screen-only export, no
  // failure. When it passes, the camera forces the composition path.
  const bool has_camera_assets =
      read.project->camera_video_path.has_value() &&
      read.project->camera_metadata_path.has_value();
  std::optional<clingfy::capture::CameraMetaFields> camera_meta;
  if (has_camera_assets) {
    if (const auto meta_json =
            ReadFileToString(fs::path(*read.project->camera_metadata_path))) {
      camera_meta = clingfy::capture::ParseCameraMetaJson(*meta_json);
    }
  }
  const bool wants_camera = ShouldCompositeCamera(
      input.camera_visible, has_camera_assets, camera_meta.has_value(),
      camera_meta.has_value() && camera_meta->preview_burned_in,
      camera_meta.has_value() ? camera_meta->frames_written : 0u);

  // Compute the destination (collision-avoided, .mov-forced). Done
  // separately from the copy so the test can pin it without touching
  // the filesystem.
  const std::string destination_utf8 =
      ResolveExportDestination(dir, input.filename, input.format);
  const fs::path destination = fs::u8path(destination_utf8);

  // Ensure the destination directory exists. The user picked it via a
  // save-as dialog so it normally already does, but being defensive
  // here means `EXPORT_ERROR` reads "copy failed" rather than something
  // more confusing.
  std::error_code ec;
  fs::create_directories(destination.parent_path(), ec);

  // The byte-for-byte copy is only valid when the export needs no work at
  // all: an identity transform (auto/auto), no Slice 3 canvas styling, no
  // Slice 4 audio processing, AND the output container matches the source.
  // The recorder always writes a .mov (QuickTime); copying its bytes to a
  // .mp4 (Slice 5A) or .gif (Slice 5B) path would mislabel/garble the
  // container, so any non-.mov request forces the composition path even with
  // auto/auto — for .gif that path drives the WIC GifEncoder instead of the
  // H.264 Sink Writer. Padding / corner radius / gain / volume / normalize each
  // force it too; a background color alone stays on the fast-path (invisible
  // without margins). The audio + format identity defaults keep the copy alive.
  const bool wants_non_mov_container =
      ResolveExportExtension(input.format) != ".mov";
  const bool needs_composition =
      !IsIdentityTransform(input.layout, input.resolution) ||
      input.padding > 0.0 || input.corner_radius > 0.0 ||
      RequiresAudioProcessing(input.audio_gain_db, input.audio_volume_percent,
                              input.auto_normalize) ||
      wants_non_mov_container || wants_sidecar || wants_camera;

  if (!needs_composition) {
    // Fast-path: pixel-for-pixel the source, so copy it byte-for-byte.
    // Lossless, instant, and it keeps the original audio + container
    // untouched — no point decoding and re-encoding a recording into an
    // identical frame. `overwrite_existing` would race with
    // `UniqueDestination`'s collision avoidance so we deliberately omit it.
    fs::copy_file(source, destination, fs::copy_options::none, ec);
    if (ec) {
      out.error = PassthroughError::kCopyFailed;
      out.message =
          "exportVideo: copy_file failed (" + ec.message() +
          "); source=" + source.u8string() +
          " destination=" + destination.u8string();
      return out;
    }
    // A cancel that landed during/just after the (sub-second) copy: drop the
    // copied file and report a clean cancel rather than leaving a stray output.
    if (is_cancelled && is_cancelled()) {
      std::error_code rm_ec;
      fs::remove(destination, rm_ec);
      out.error = PassthroughError::kCancelled;
      out.message = "exportVideo: cancelled by user";
      return out;
    }
    // The byte-copy is instant; report 100% so the UI completes.
    if (on_progress) {
      on_progress(1.0);
    }
  } else {
    // Composition path: decode the recording, composite each frame at the
    // requested resolution / layout / fit with the Slice 3 styling, scale the
    // audio by the Slice 4 gain / volume / normalize multiplier, and re-encode.
    RenderRequest render;
    render.source_video_path = read.project->screen_path;
    render.destination_path = destination.u8string();
    render.layout = input.layout;
    render.resolution = input.resolution;
    render.fit = input.fit;
    render.padding = input.padding;
    render.corner_radius = input.corner_radius;
    render.background_color = input.background_color;
    render.audio_gain_db = input.audio_gain_db;
    render.audio_volume_percent = input.audio_volume_percent;
    render.auto_normalize = input.auto_normalize;
    render.target_loudness_dbfs = input.target_loudness_dbfs;
    render.bitrate = input.bitrate;
    // Phase 8.2/8.3: cursor + zoom share the sidecar path; set it when EITHER is
    // active so each feature can read it independently.
    render.show_cursor = wants_cursor_render;
    render.cursor_size = input.cursor_size;
    render.zoom_enabled = wants_zoom;
    render.zoom_factor = input.zoom_factor;
    render.cursor_sidecar_path =
        wants_sidecar ? cursor_sidecar.wstring() : std::wstring();
    // Phase 9.4: camera bubble. Only set when the gate passed; the pipeline
    // still soft-fails internally if the reader/D2D resources can't be built.
    if (wants_camera) {
      render.draw_camera = true;
      render.camera_video_path = *read.project->camera_video_path;
      render.camera_start_offset_ms = camera_meta->start_offset_ms;
      render.camera_has_center = input.camera_has_center;
      render.camera_center_x = input.camera_center_x;
      render.camera_center_y = input.camera_center_y;
      render.camera_layout_preset = input.camera_layout_preset;
      render.camera_size_factor = input.camera_size_factor;
      render.camera_shape = input.camera_shape;
      render.camera_corner_radius = input.camera_corner_radius;
      render.camera_content_mode = input.camera_content_mode;
    }
    render.on_progress = on_progress;
    render.is_cancelled = is_cancelled;
    render.fps_hint = read.project->metadata.has_value()
                          ? read.project->metadata->fps
                          : 0u;
    const RenderResult render_result = RenderComposedExport(render);
    if (!render_result.ok) {
      if (render_result.cancelled) {
        out.error = PassthroughError::kCancelled;
        out.message = "exportVideo: cancelled by user";
      } else {
        out.error = PassthroughError::kRenderFailed;
        out.message = "exportVideo: composition render failed — " +
                      render_result.message;
      }
      return out;
    }
  }

  out.output_path = destination.u8string();
  // Windows now produces .mov, .mp4, AND .gif natively (Slices 5A/5B), so
  // nothing is downgraded; FormatWasDowngraded always returns false now but is
  // kept as the result-contract field.
  out.format_was_downgraded = FormatWasDowngraded(input.format);
  return out;
}

}  // namespace clingfy::capture::export_
