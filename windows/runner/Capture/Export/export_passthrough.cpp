#include "Capture/Export/export_passthrough.h"

#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <optional>
#include <sstream>
#include <string>
#include <system_error>

#include "Bridge/native_log_publisher.h"
#include "Capture/Camera/camera_meta.h"
#include "Capture/Export/audio_sidecar_probe.h"
#include "Capture/Export/export_audio.h"
#include "Capture/Export/export_format.h"
#include "Capture/Export/export_geometry.h"
#include "Capture/Export/export_pipeline.h"
#include "Capture/Export/mic_cleanup.h"
#include "Capture/recording_project_reader.h"
#include "Encoding/mf_encoder_config.h"
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
  // Non-throwing fs::exists only (Phase 10.4): the runner builds with
  // _HAS_EXCEPTIONS=0, so a THROWING overload that hits a real error (e.g.
  // an access-denied destination dir) fail-fasts and kills the process
  // instead of raising a catchable filesystem_error. An errored probe reads
  // as "does not exist" and the export proceeds — the real failure then
  // surfaces downstream as a clean kCopyFailed / kRenderFailed.
  std::error_code ec;
  fs::path candidate = dir / (stem + ext);
  if (!fs::exists(candidate, ec)) {
    return candidate;
  }
  for (int i = 1; i < 1000; ++i) {
    candidate = dir / (stem + " (" + std::to_string(i) + ")" + ext);
    ec.clear();
    if (!fs::exists(candidate, ec)) {
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

ClipEditKind ClassifyClipEdit(
    const std::vector<clip_planner::ClipKeptRange>& ranges) {
  const auto coalesced = clip_planner::Coalesce(ranges);
  // A split with nothing deleted coalesces back to one contiguous window from
  // source 0 → not a real edit. A single range starting at source 0 (incl. a
  // pure tail-trim, indistinguishable from the full range without the asset
  // duration) also stays passthrough.
  const bool has_real_edits =
      coalesced.size() > 1 ||
      (coalesced.size() == 1 && coalesced[0].source_in_ms > 0);
  if (!has_real_edits) {
    return ClipEditKind::kPassthrough;
  }
  // Any real edit bakes via the composition path. Monotonic + disjoint ranges
  // (cut / trim / delete-middle) forward-read the source once; reorder and
  // overlap read each source window in timeline order (per-range backward
  // seeks, 3b-2). The pipeline picks the path via IsSourceMonotonic.
  return ClipEditKind::kBake;
}

std::int64_t EstimateRequiredExportBytes(std::int64_t source_size_bytes,
                                         bool composition) {
  if (source_size_bytes < 0) {
    return -1;
  }
  return source_size_bytes + (composition ? kCompositionDiskHeadroomBytes
                                          : kPassthroughDiskHeadroomBytes);
}

bool ExportDiskPreflightFits(std::int64_t required_bytes,
                             std::int64_t available_bytes) {
  if (required_bytes <= 0 || available_bytes < 0) {
    // Unknown estimate / failed free-space probe: never block the export on
    // a probe failure — a genuinely full disk still fails downstream and is
    // classified by its disk-full HRESULT / errno.
    return true;
  }
  return available_bytes >= required_bytes;
}

std::string FormatBytesForUser(std::int64_t bytes) {
  if (bytes < 0) {
    bytes = 0;
  }
  char buf[32];
  if (bytes >= 1'000'000'000) {
    std::snprintf(buf, sizeof(buf), "%.1f GB",
                  static_cast<double>(bytes) / 1'000'000'000.0);
  } else {
    std::snprintf(buf, sizeof(buf), "%.1f MB",
                  static_cast<double>(bytes) / 1'000'000.0);
  }
  return std::string(buf);
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

  // Audio separation (D7/D8): a SEPARATED recording (decodable mic/system
  // sidecar) always takes the composition path — macOS never byte-copies a
  // separated export, because the copy would ship the embedded premix and
  // silently ignore mic-only gain/normalize. The reader already
  // existence-gated the paths; the decode-one-sample probe is the same gate
  // preview uses, so an undecodable (truncated/corrupt) sidecar cleanly
  // degrades to today's embedded whole-track behavior. GIF exports carry no
  // audio — skip the probes entirely.
  const bool gif_export = ResolveExportExtension(input.format) == ".gif";
  const bool mic_sidecar_decodable =
      !gif_export && read.project->mic_audio_path.has_value() &&
      ProbeDecodableAudio(*read.project->mic_audio_path);
  const bool system_sidecar_decodable =
      !gif_export && read.project->system_audio_path.has_value() &&
      ProbeDecodableAudio(*read.project->system_audio_path);
  const bool wants_separated_audio =
      mic_sidecar_decodable || system_sidecar_decodable;

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
  // Editing port (clips): the export BAKES every real clip edit — cuts / trims
  // / delete-middle (the pipeline drops cut source frames and re-stamps the
  // survivors onto a compacted timeline) AND reorder / overlap (3b-2 reads each
  // source window in timeline order with a sample-accurate audio stitch). A
  // split with nothing deleted coalesces back to one contiguous window from
  // source 0 and is NOT an edit, so it stays on the copy fast-path. (A pure
  // tail-trim — one range from source 0 — is indistinguishable from the full
  // range without the asset duration, so it rides the fast-path as before;
  // harmless, the removed tail is past the last kept frame either way.)
  bool wants_clips = false;
  switch (ClassifyClipEdit(input.clip_ranges)) {
    case ClipEditKind::kPassthrough:
      break;  // no real edit — stays eligible for the copy fast-path
    case ClipEditKind::kBake:
      wants_clips = true;  // real edit — forces composition below
      break;
  }

  const bool wants_non_mov_container =
      ResolveExportExtension(input.format) != ".mov";
  // Editing port (color): a non-identity grade must force the composition
  // path — the byte-copy would silently ship an UNGRADED file while
  // reporting success (the classic passthrough landmine).
  const bool wants_color_grade = !input.color_grade.IsIdentity();
  // Editing port (clips): a real clip edit must force the composition path —
  // the byte-copy would ship the UNCUT source while reporting success (the
  // passthrough landmine). Reorder/overlap bake too (3b-2, per-range seeks).
  // Audio separation: a separated recording must compose even at identity
  // settings — the byte-copy would ship the premix (see the probe above).
  // Codec: the recording is always H.264, so asking for HEVC is a real change
  // to the output and must force a re-encode. The byte-copy would otherwise
  // ship the H.264 source while reporting success — the same passthrough
  // landmine as an ungraded or uncut file, and the reason a codec setting can
  // look inert even after the encoder learns HEVC.
  //
  // Gated on AVAILABILITY, not just the request: on a machine with no HEVC
  // encoder the export is going to produce H.264 either way, so forcing a
  // pointless re-encode there would cost the user a lossless instant copy and
  // give them nothing.
  const bool wants_hevc =
      clingfy::encoding::ResolveVideoCodec(
          clingfy::encoding::ParseVideoCodec(input.codec), nullptr) ==
      clingfy::encoding::VideoCodec::kHevc;
  const bool needs_composition =
      !IsIdentityTransform(input.layout, input.resolution) ||
      input.padding > 0.0 || input.corner_radius > 0.0 ||
      RequiresAudioProcessing(input.audio_gain_db, input.audio_volume_percent,
                              input.auto_normalize) ||
      wants_non_mov_container || wants_sidecar || wants_camera ||
      wants_color_grade || wants_clips || wants_separated_audio || wants_hevc;

  // Phase 10.4 disk-full preflight: estimate the bytes the export needs at
  // the destination (source size + headroom for the chosen path) and compare
  // against the destination volume's free space. A failed probe soft-fails
  // (never blocks); a confident "won't fit" is surfaced as kDiskFull BEFORE
  // any partial output is written.
  {
    std::error_code size_ec;
    const auto source_size = fs::file_size(source, size_ec);
    const std::int64_t source_bytes =
        size_ec ? -1 : static_cast<std::int64_t>(source_size);
    const std::int64_t required =
        EstimateRequiredExportBytes(source_bytes, needs_composition);
    ULARGE_INTEGER free_bytes{};
    std::int64_t available = -1;
    if (::GetDiskFreeSpaceExW(destination.parent_path().c_str(), &free_bytes,
                              nullptr, nullptr) != FALSE) {
      available = static_cast<std::int64_t>(free_bytes.QuadPart);
    }
    if (!ExportDiskPreflightFits(required, available)) {
      out.error = PassthroughError::kDiskFull;
      out.disk_required_bytes = required;
      out.disk_available_bytes = available;
      out.disk_checked_path = destination.parent_path().u8string();
      // Self-contained human string (mirrors the macOS disk-full reason):
      // it must stand on its own in logs / Sentry / fallback dialogs even
      // though Dart re-renders a localized message from the details payload.
      out.message =
          "Not enough free disk space to export this recording. About " +
          FormatBytesForUser(required) +
          " is needed at the destination, only " +
          FormatBytesForUser(available) + " is available (short by " +
          FormatBytesForUser(required - available) +
          "). Free up some space and try again.";
      return out;
    }
  }

  if (!needs_composition) {
    // Fast-path: pixel-for-pixel the source, so copy it byte-for-byte.
    // Lossless, instant, and it keeps the original audio + container
    // untouched — no point decoding and re-encoding a recording into an
    // identical frame. `overwrite_existing` would race with
    // `UniqueDestination`'s collision avoidance so we deliberately omit it.
    fs::copy_file(source, destination, fs::copy_options::none, ec);
    if (ec) {
      // Phase 10.4: a failed copy can leave a partial destination file —
      // never leave corrupt output at the user-chosen path. The destination
      // was freshly created by UniqueDestination, so removal can never
      // clobber a pre-existing user file.
      std::error_code rm_ec;
      fs::remove(destination, rm_ec);
      if (ec == std::errc::no_space_on_device) {
        out.error = PassthroughError::kDiskFull;
        out.disk_checked_path = destination.parent_path().u8string();
        out.message =
            "Not enough free disk space to finish this export — the "
            "destination disk filled up while copying. Free up some space "
            "and try again. (destination=" +
            destination.u8string() + ")";
      } else {
        out.error = PassthroughError::kCopyFailed;
        out.message =
            "exportVideo: copy_file failed (" + ec.message() +
            "); source=" + source.u8string() +
            " destination=" + destination.u8string();
      }
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
    // Per-export temp holding the RNNoise-cleaned mic (Phase 4). Kept in this
    // scope so it outlives RenderComposedExport below, then deleted right after
    // the render returns.
    std::optional<fs::path> cleaned_mic_temp;
    std::optional<fs::path> echo_mic_temp;
    render.source_video_path = read.project->screen_path;
    render.destination_path = destination.u8string();
    render.layout = input.layout;
    render.resolution = input.resolution;
    render.fit = input.fit;
    render.padding = input.padding;
    render.corner_radius = input.corner_radius;
    render.background_color = input.background_color;
    render.background_image_path = input.background_image_path;
    render.background_preset = input.background_preset;
    render.has_background_preset = input.has_background_preset;
    // Editing port (color): bake the grade into the composite (identity is a
    // no-op inside the pipeline).
    render.color_grade = input.color_grade;
    // Editing port (clips): bake the clip edit. Empty = identity; the pipeline
    // picks the monotonic forward-read or the reorder per-range-seek path via
    // IsSourceMonotonic (drop cut frames + re-stamp onto edited PTS).
    render.clip_ranges = input.clip_ranges;
    render.audio_gain_db = input.audio_gain_db;
    render.audio_volume_percent = input.audio_volume_percent;
    render.auto_normalize = input.auto_normalize;
    render.target_loudness_dbfs = input.target_loudness_dbfs;
    // Audio separation: only PROBED paths reach the pipeline (its contract
    // is that a non-empty path decodes).
    if (mic_sidecar_decodable) {
      render.mic_audio_path = *read.project->mic_audio_path;
      // Speaker-to-mic bleed removal, FIRST among the mic passes.
      //
      // Order is load-bearing. It must run before voice cleanup, whose noise
      // suppression would distort the very bleed the correlation needs to find
      // it, and before the normalize peak scan, which would otherwise measure a
      // peak inflated by the echo.
      //
      // Only meaningful when BOTH sidecars exist: with no system track there is
      // no reference to cancel against. Best-effort throughout — a false return
      // (including the common "no bleed found") leaves the raw mic in place.
      if (input.mic_echo_cancellation_enabled && system_sidecar_decodable) {
        fs::path decoupled = destination;
        decoupled += ".micecho.mp4";
        EchoCancelReport report;
        if (ProduceEchoCancelledMic(*read.project->mic_audio_path,
                                    *read.project->system_audio_path,
                                    decoupled.u8string(), is_cancelled,
                                    &report)) {
          render.mic_audio_path = decoupled.wstring();
          echo_mic_temp = decoupled;
          char buf[192];
          std::snprintf(buf, sizeof(buf),
                        "echo cancellation applied: correlation %.2f, delay "
                        "%.1f ms, residual %.1f dB",
                        report.bleed_correlation, report.delay_ms,
                        report.reduction_db);
          clingfy::bridge::NativeLogPublisher::Instance().Info("Export", buf);
        } else {
          std::error_code echo_ec;
          fs::remove(decoupled, echo_ec);
          clingfy::bridge::NativeLogPublisher::Instance().Debug(
              "Export",
              report.applied
                  ? "echo cancellation failed; exporting the raw mic"
                  : "no measurable speaker bleed; exporting the raw mic");
        }
      }
      // Phase 4 voice cleanup: run the mic through RNNoise before the audio
      // pump. Best-effort -- a failed clean leaves render.mic_audio_path on the
      // raw sidecar, so the export just skips denoising rather than failing.
      if (input.voice_cleanup_enabled) {
        fs::path cleaned = destination;
        cleaned += ".miccleanup.mp4";
        // Chain from whatever the echo pass produced, not from the raw
        // sidecar, or enabling both would silently discard the cancellation.
        if (ProduceCleanedMic(render.mic_audio_path, cleaned.u8string(),
                              is_cancelled,
                              VoiceCleanupWetMix(input.voice_cleanup_mode))) {
          render.mic_audio_path = cleaned.wstring();
          cleaned_mic_temp = cleaned;
        } else {
          std::error_code clean_ec;
          fs::remove(cleaned, clean_ec);
          clingfy::bridge::NativeLogPublisher::Instance().Warn(
              "Export", "voice cleanup failed; exporting the raw mic");
        }
      }
    }
    if (system_sidecar_decodable) {
      render.system_audio_path = *read.project->system_audio_path;
    }
    render.bitrate = input.bitrate;
    render.codec = input.codec;
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
      render.camera_mirror = input.camera_mirror;
      render.camera_opacity = input.camera_opacity;
      render.camera_border_width = input.camera_border_width;
      render.camera_border_color_argb = input.camera_border_color_argb;
      render.camera_shadow_preset = input.camera_shadow_preset;
      render.camera_chroma_enabled = input.camera_chroma_enabled;
      render.camera_chroma_strength = input.camera_chroma_strength;
      render.camera_chroma_color_argb = input.camera_chroma_color_argb;
      render.camera_intro_preset = input.camera_intro_preset;
      render.camera_outro_preset = input.camera_outro_preset;
      render.camera_intro_duration_ms = input.camera_intro_duration_ms;
      render.camera_outro_duration_ms = input.camera_outro_duration_ms;
      render.camera_zoom_behavior = input.camera_zoom_behavior;
      render.camera_zoom_scale_multiplier = input.camera_zoom_scale_multiplier;
      render.camera_zoom_emphasis_preset = input.camera_zoom_emphasis_preset;
      render.camera_zoom_emphasis_strength =
          input.camera_zoom_emphasis_strength;
    }
    render.on_progress = on_progress;
    render.is_cancelled = is_cancelled;
    render.fps_hint = read.project->metadata.has_value()
                          ? read.project->metadata->fps
                          : 0u;
    const RenderResult render_result = RenderComposedExport(render);
    // The cleaned-mic temp (if any) has served the render; drop it regardless
    // of outcome. render.mic_audio_path is not read past this point.
    if (cleaned_mic_temp) {
      std::error_code clean_ec;
      fs::remove(*cleaned_mic_temp, clean_ec);
    }
    if (echo_mic_temp) {
      std::error_code echo_ec;
      fs::remove(*echo_mic_temp, echo_ec);
    }
    if (!render_result.ok) {
      if (render_result.cancelled) {
        // Cancel cleanup is owned by the pipeline (Cancelled() removed the
        // partial output before returning).
        out.error = PassthroughError::kCancelled;
        out.message = "exportVideo: cancelled by user";
        return out;
      }
      // Phase 10.4: never leave a corrupt file (e.g. a moov-less MP4 after a
      // failed Finalize) at the user-chosen destination. The pipeline already
      // removes it best-effort; retry here because its encoder objects are
      // destroyed by now, so a removal that lost a file-handle race inside
      // the pipeline succeeds on this second attempt. The destination is
      // always freshly created via UniqueDestination, so this can never
      // delete a pre-existing user file.
      std::error_code rm_ec;
      fs::remove(destination, rm_ec);
      std::error_code exists_ec;
      if (fs::exists(destination, exists_ec)) {
        // Both best-effort removals lost — typically a transient external
        // lock (AV / Search indexer scanning the just-written partial). Say
        // so: a silent leftover is what turns a failed export into a corrupt
        // file sitting at the user's chosen name.
        clingfy::bridge::NativeLogPublisher::Instance().Warn(
            "Export",
            "could not remove the partial output at " + destination.u8string() +
                (rm_ec ? " (" + rm_ec.message() + ")" : ""));
      }
      out.resolved_destination_path = destination.u8string();
      if (render_result.disk_full) {
        // The encoder hit a disk-full HRESULT mid-write. No preflight
        // estimate exists at this point (required stays -1); the router
        // falls back to this self-contained message.
        out.error = PassthroughError::kDiskFull;
        out.disk_checked_path = destination.parent_path().u8string();
        out.message =
            "Not enough free disk space to finish this export — the "
            "destination disk filled up while writing. Free up some space "
            "and try again. (" +
            render_result.message + ")";
      } else {
        out.error = PassthroughError::kRenderFailed;
        out.device_removed = render_result.device_removed;
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

bool ShouldRetryExportAfterDeviceRemoved(const PassthroughResult& outcome,
                                         int attempts_so_far,
                                         bool cancel_requested) {
  return attempts_so_far == 1 && !cancel_requested &&
         outcome.error == PassthroughError::kRenderFailed &&
         outcome.device_removed;
}

}  // namespace clingfy::capture::export_
