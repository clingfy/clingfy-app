#include "Capture/recording_project_writer.h"

#include <windows.h>
#include <shlobj.h>

#include <charconv>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>

namespace clingfy::capture {

namespace {

namespace fs = std::filesystem;

// Escape a UTF-8 string for embedding in a JSON literal. Conservative —
// only the characters JSON forbids in a string get escaped; everything
// else passes through (including non-ASCII bytes, which JSON parsers
// accept as UTF-8).
std::string JsonEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 2);
  for (char c : value) {
    switch (c) {
      case '\\':
        out += "\\\\";
        break;
      case '"':
        out += "\\\"";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          // Other control characters — JSON requires `\uXXXX`.
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x",
                        static_cast<unsigned int>(c));
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

// Format a double as compact JSON. `std::to_chars` emits the shortest string
// that round-trips back to the same double, always with '.' as the separator
// (locale-independent) and no trailing-zero noise — mirroring how Swift's
// JSONEncoder renders 1.0 -> "1", 0.35 -> "0.35", while guaranteeing the
// writer→reader round-trip is lossless.
std::string JsonNumber(double v) {
  char buf[32];
  const auto res = std::to_chars(buf, buf + sizeof(buf), v);
  return std::string(buf, res.ptr);
}

// Emit the `editorSeed` object (the recording-time camera composition) using
// the macOS `RecordingMetadata.EditorSeed` on-disk keys, so a Windows-written
// screen.meta.json decodes on macOS too. All 12 always-required macOS fields
// are emitted; the three nullable fields (cameraNormalizedCenter,
// cameraBorderColorArgb, cameraChromaKeyColorArgb) are omitted when absent,
// matching JSONEncoder's `encodeIfPresent`. Written as a value only — the
// caller supplies the `"editorSeed":` key and any trailing comma.
void AppendEditorSeedJson(std::ostringstream& out, const CameraEditorSeed& s) {
  out << "{\n";
  bool first = true;
  const auto field = [&](const char* key, const std::string& value) {
    if (!first) out << ",\n";
    first = false;
    out << "    \"" << key << "\": " << value;
  };
  const auto quoted = [](const std::string& v) {
    return "\"" + JsonEscape(v) + "\"";
  };
  field("cameraVisible", s.visible ? "true" : "false");
  field("cameraLayoutPreset", quoted(s.layout_preset));
  if (s.normalized_center_x.has_value() && s.normalized_center_y.has_value()) {
    field("cameraNormalizedCenter",
          "{\"x\": " + JsonNumber(*s.normalized_center_x) +
              ", \"y\": " + JsonNumber(*s.normalized_center_y) + "}");
  }
  field("cameraSizeFactor", JsonNumber(s.size_factor));
  field("cameraShape", quoted(s.shape));
  field("cameraCornerRadius", JsonNumber(s.corner_radius));
  field("cameraBorderWidth", JsonNumber(s.border_width));
  if (s.border_color_argb.has_value()) {
    field("cameraBorderColorArgb", std::to_string(*s.border_color_argb));
  }
  field("cameraShadow", std::to_string(s.shadow_preset));
  field("cameraOpacity", JsonNumber(s.opacity));
  field("cameraMirror", s.mirror ? "true" : "false");
  field("cameraContentMode", quoted(s.content_mode));
  field("cameraZoomBehavior", quoted(s.zoom_behavior));
  field("cameraZoomScaleMultiplier", JsonNumber(s.zoom_scale_multiplier));
  field("cameraIntroPreset", quoted(s.intro_preset));
  field("cameraOutroPreset", quoted(s.outro_preset));
  field("cameraZoomEmphasisPreset", quoted(s.zoom_emphasis_preset));
  field("cameraIntroDurationMs", std::to_string(s.intro_duration_ms));
  field("cameraOutroDurationMs", std::to_string(s.outro_duration_ms));
  field("cameraZoomEmphasisStrength", JsonNumber(s.zoom_emphasis_strength));
  field("cameraChromaKeyEnabled", s.chroma_key_enabled ? "true" : "false");
  field("cameraChromaKeyStrength", JsonNumber(s.chroma_key_strength));
  if (s.chroma_key_color_argb.has_value()) {
    field("cameraChromaKeyColorArgb",
          std::to_string(*s.chroma_key_color_argb));
  }
  out << "\n  }";
}

bool WriteUtf8File(const fs::path& path, const std::string& contents) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out.is_open()) {
    return false;
  }
  out.write(contents.data(),
            static_cast<std::streamsize>(contents.size()));
  return out.good();
}

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                        static_cast<int>(wide.size()), out.data(), needed,
                        nullptr, nullptr);
  return out;
}

}  // namespace

std::string CurrentIso8601Timestamp() {
  const auto now = std::chrono::system_clock::now();
  const auto secs = std::chrono::time_point_cast<std::chrono::seconds>(now);
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      now - secs).count();
  const std::time_t time = std::chrono::system_clock::to_time_t(secs);
  std::tm utc{};
#ifdef _WIN32
  ::gmtime_s(&utc, &time);
#else
  ::gmtime_r(&time, &utc);
#endif
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday,
                utc.tm_hour, utc.tm_min, utc.tm_sec,
                static_cast<int>(ms));
  return std::string(buf);
}

std::string ResolveDefaultRecordingsRoot() {
#ifdef _WIN32
  // Phase 10.3 test/support seam (mirrors CLINGFY_DEFAULT_SAVE_FOLDER):
  // lets the storage-router tests point the snapshot/clear handlers at a
  // temp directory instead of the real per-user recordings root.
  {
    const DWORD needed =
        ::GetEnvironmentVariableW(L"CLINGFY_RECORDINGS_ROOT", nullptr, 0);
    if (needed > 1) {
      std::wstring value(needed, L'\0');
      const DWORD written = ::GetEnvironmentVariableW(
          L"CLINGFY_RECORDINGS_ROOT", value.data(), needed);
      if (written > 0 && written < needed) {
        value.resize(written);
        return Utf8FromWide(value);
      }
    }
  }
  PWSTR raw_path = nullptr;
  HRESULT hr = ::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                       &raw_path);
  std::string base;
  if (SUCCEEDED(hr) && raw_path != nullptr) {
    base = Utf8FromWide(std::wstring(raw_path));
    ::CoTaskMemFree(raw_path);
  }
  if (base.empty()) {
    base = "C:\\Users\\Default\\AppData\\Local";
  }
  fs::path root = fs::path(base) / "Clingfy" / "recordings";
  return root.string();
#else
  return std::string("/tmp/clingfy/recordings");
#endif
}

std::string BuildManifestJson(const ProjectWriterInput& input) {
  // Layout mirrors macOS's `RecordingProjectManifest` exactly so
  // `RecordingProjectRef.open(projectPath:)` accepts the file with no
  // platform branching.
  const std::string created_at = input.created_at_iso8601.empty()
                                       ? CurrentIso8601Timestamp()
                                       : input.created_at_iso8601;
  std::ostringstream out;
  out << "{\n";
  out << "  \"schemaVersion\": 2,\n";
  out << "  \"projectId\": \"" << JsonEscape(input.session_id) << "\",\n";
  out << "  \"createdAt\": \"" << JsonEscape(created_at) << "\",\n";
  out << "  \"updatedAt\": \"" << JsonEscape(created_at) << "\",\n";
  out << "  \"displayName\": \"" << JsonEscape(input.session_id) << "\",\n";
  // Phase 10.4 status lifecycle (macOS `RecordingProjectStatus` parity):
  // "capturing" while recording, "ready" after a successful Stop, "failed"
  // for interrupted/unfinalizable recordings. Openable statuses are
  // ready/cancelled/failed — see `RecordingProjectManifestError
  // .projectStatusNotOpenable` (Dart) and the Windows reader's status gate.
  out << "  \"status\": \""
      << JsonEscape(input.status.empty() ? "ready" : input.status)
      << "\",\n";
  // Phase 10.4: PID of the recording process. The startup recovery sweep
  // skips "capturing" bundles whose owner is still alive (dev + prod share
  // the recordings root until 10.5). Readers ignore unknown keys.
  if (input.owner_pid != 0) {
    out << "  \"ownerPid\": " << input.owner_pid << ",\n";
  }
  out << "  \"capture\": {\n";
  out << "    \"screenVideo\": \"capture/screen.mov\",\n";
  out << "    \"screenMetadata\": \"capture/screen.meta.json\",\n";
  // Phase 8.1: point at the streamed `cursor.jsonl` when a sidecar was bundled;
  // otherwise keep the macOS-default `cursor.json` placeholder name.
  out << "    \"cursorData\": \""
      << (input.cursor_enabled ? "capture/cursor.jsonl" : "capture/cursor.json")
      << "\",\n";
  // Audio separation: the macOS Phase 1.5 sidecar keys, emitted only for a
  // sidecar that was actually bundled (macOS's keys are nullable — absent
  // means "no separated source"). Additive; readers on both platforms
  // ignore unknown keys, so schemaVersion stays 2.
  if (input.mic_audio_enabled) {
    out << "    \"micAudio\": \"capture/mic.m4a\",\n";
  }
  if (input.system_audio_enabled) {
    out << "    \"systemAudio\": \"capture/system.m4a\",\n";
  }
  out << "    \"zoomManual\": \"capture/zoom.manual.json\"\n";
  out << "  },\n";
  // Phase 9.2: the camera block is emitted ONLY when a camera was actually
  // recorded (recorder ran + produced frames + the raw was bundled). The reader
  // treats an absent block as "no camera", so omitting it for camera-less
  // recordings is correct — and avoids the old placeholder that pointed at
  // files that never existed. `metadata` matches the camera/camera.meta.json the
  // writer emits below.
  if (input.camera_enabled) {
    out << "  \"camera\": {\n";
    out << "    \"rawVideo\": \"camera/raw.mov\",\n";
    out << "    \"metadata\": \"camera/camera.meta.json\",\n";
    out << "    \"segmentsDirectory\": \"camera/segments\"\n";
    out << "  },\n";
  }
  out << "  \"post\": {\n";
  out << "    \"state\": \"post/state.json\",\n";
  out << "    \"thumbnail\": \"post/thumbnail.jpg\"\n";
  out << "  },\n";
  out << "  \"derived\": {\n";
  out << "    \"waveform\": \"derived/waveform.json\"\n";
  out << "  },\n";
  out << "  \"exportHistory\": []\n";
  out << "}\n";
  return out.str();
}

std::string BuildScreenMetaJson(const ProjectWriterInput& input) {
  std::ostringstream out;
  out << "{\n";
  out << "  \"width\": " << input.width << ",\n";
  out << "  \"height\": " << input.height << ",\n";
  out << "  \"fps\": " << input.fps << ",\n";
  out << "  \"framesReceived\": " << input.frames_received << ",\n";
  out << "  \"framesDropped\": " << input.frames_dropped << ",\n";
  out << "  \"audioSamplesWritten\": " << input.audio_samples_written
      << ",\n";
  out << "  \"micActive\": " << (input.mic_active ? "true" : "false")
      << ",\n";
  out << "  \"loopbackActive\": "
      << (input.loopback_active ? "true" : "false") << ",\n";
  // Phase 8.1: whether a cursor sidecar (capture/cursor.jsonl) accompanies this
  // recording. Additive — the reader ignores unknown keys.
  out << "  \"cursorEnabled\": "
      << (input.cursor_enabled ? "true" : "false") << ",\n";
  // Phase 7.1: capture target type ("display" | "window" | "area") + the
  // window id for window captures. Additive fields — the manifest reader
  // ignores unknown keys, so schemaVersion stays 2.
  out << "  \"targetType\": \"" << JsonEscape(input.target_type) << "\",\n";
  if (input.window_id.has_value()) {
    out << "  \"windowId\": " << *input.window_id << ",\n";
  }
  if (input.source_bounds.has_value()) {
    const auto& b = *input.source_bounds;
    out << "  \"sourceBounds\": {\"x\": " << b.x << ", \"y\": " << b.y
        << ", \"width\": " << b.width << ", \"height\": " << b.height
        << "},\n";
  }
  // Phase 5.2 parity: the recording-time camera composition. macOS always
  // persists an editorSeed; the reader (ParseScreenMetaJson) and
  // getRecordingSceneInfo read it back so post-processing opens camera-on with
  // the recorded settings. Additive — the reader ignores it on old bundles.
  out << "  \"editorSeed\": ";
  AppendEditorSeedJson(out, input.editor_seed);
  out << ",\n";
  out << "  \"platform\": \"windows\"\n";
  out << "}\n";
  return out.str();
}

ProjectWriterResult WriteRecordingProject(const ProjectWriterInput& input) {
  if (input.session_id.empty()) {
    return {ProjectWriterErrorKind::kBadInput,
            "session_id is required for the project writer.", {}};
  }
  if (input.source_mp4_path.empty()) {
    return {ProjectWriterErrorKind::kBadInput,
            "source_mp4_path is required for the project writer.", {}};
  }

  const std::string root = input.recordings_root_override.empty()
                                ? ResolveDefaultRecordingsRoot()
                                : input.recordings_root_override;

  std::error_code ec;
  // Phase 10.4 (review fix): the root string is UTF-8
  // (ResolveDefaultRecordingsRoot / the env seam) — decode it as such.
  // `fs::path(std::string)` uses the ACTIVE CODE PAGE on MSVC, which sent
  // the bundle to a different directory than the UTF-8-decoding recovery
  // sweep / storage router on non-ASCII user profiles.
  fs::path project_root =
      fs::u8path(root) / (input.session_id + ".clingfyproj");
  fs::create_directories(project_root, ec);
  if (ec) {
    return {ProjectWriterErrorKind::kFilesystem,
            "Failed to create project root: " + ec.message(), {}};
  }
  fs::create_directories(project_root / "capture", ec);
  fs::create_directories(project_root / "post", ec);
  if (ec) {
    return {ProjectWriterErrorKind::kFilesystem,
            "Failed to create project subdirectories: " + ec.message(), {}};
  }

  const fs::path source = fs::u8path(input.source_mp4_path);
  if (!fs::exists(source, ec)) {
    return {ProjectWriterErrorKind::kSourceMissing,
            "Source MP4 not found: " + input.source_mp4_path, {}};
  }
  const fs::path screen = project_root / "capture" / "screen.mov";
  // Prefer rename for speed, fall back to copy + remove if the source
  // is on a different drive than `%LOCALAPPDATA%`. Either way the temp
  // file is gone after success.
  fs::rename(source, screen, ec);
  if (ec) {
    ec.clear();
    fs::copy_file(source, screen, fs::copy_options::overwrite_existing, ec);
    if (ec) {
      return {ProjectWriterErrorKind::kFilesystem,
              "Failed to move encoder MP4 into project: " + ec.message(),
              {}};
    }
    fs::remove(source, ec);
    ec.clear();
  }

  // Phase 8.1: bundle the cursor sidecar (best-effort). The recording is valid
  // without it, so a missing / unmovable sidecar downgrades `cursor_enabled`
  // rather than failing the whole project. `effective` carries the actual
  // outcome into the manifest builders.
  ProjectWriterInput effective = input;
  effective.cursor_enabled = false;
  if (input.cursor_enabled && !input.cursor_sidecar_path.empty()) {
    const fs::path cursor_src = fs::u8path(input.cursor_sidecar_path);
    std::error_code cursor_ec;
    if (fs::exists(cursor_src, cursor_ec)) {
      const fs::path cursor_dst = project_root / "capture" / "cursor.jsonl";
      fs::rename(cursor_src, cursor_dst, cursor_ec);
      if (cursor_ec) {
        cursor_ec.clear();
        fs::copy_file(cursor_src, cursor_dst,
                      fs::copy_options::overwrite_existing, cursor_ec);
        if (!cursor_ec) {
          fs::remove(cursor_src, cursor_ec);
          cursor_ec.clear();
        }
      }
      if (fs::exists(cursor_dst, cursor_ec)) {
        effective.cursor_enabled = true;
      }
    }
  }

  // Phase 9.2: bundle the camera raw + write its metadata sidecar (best-effort,
  // same discipline as the cursor sidecar). The recording is valid without a
  // camera, so any failure here downgrades `camera_enabled` (the manifest then
  // omits the camera block) rather than failing the whole project.
  effective.camera_enabled = false;
  if (input.camera_enabled && !input.camera_raw_path.empty()) {
    const fs::path camera_src = fs::u8path(input.camera_raw_path);
    std::error_code cam_ec;
    if (fs::exists(camera_src, cam_ec)) {
      fs::create_directories(project_root / "camera", cam_ec);
      const fs::path camera_dst = project_root / "camera" / "raw.mov";
      cam_ec.clear();
      fs::rename(camera_src, camera_dst, cam_ec);
      if (cam_ec) {
        cam_ec.clear();
        fs::copy_file(camera_src, camera_dst,
                      fs::copy_options::overwrite_existing, cam_ec);
        if (!cam_ec) {
          fs::remove(camera_src, cam_ec);
          cam_ec.clear();
        }
      }
      // Both the raw AND the metadata must land for the reader's
      // present-together rule; write the sidecar only after the raw is in place.
      if (fs::exists(camera_dst, cam_ec)) {
        if (WriteUtf8File(project_root / "camera" / "camera.meta.json",
                          input.camera_meta_json)) {
          effective.camera_enabled = true;
        } else {
          // Meta write failed — drop the now-orphan raw so the bundle never
          // contains exactly one of the pair (and stays clean of dead weight).
          fs::remove(camera_dst, cam_ec);
        }
      }
    }
  }

  // Audio separation: bundle the mic / system sidecars (best-effort, each
  // independently — same discipline as the cursor sidecar). The recording
  // is valid without either (the premixed track in screen.mov is intact),
  // so any failure downgrades that sidecar's flag and its manifest key is
  // omitted. The `.mp4`→`.m4a` rename is just a name change — the MPEG-4
  // container is identical; the `.m4a` name matches macOS Phase 1.5.
  const auto bundle_audio_sidecar = [&project_root](
                                        const std::string& src_path,
                                        const char* dst_name) -> bool {
    const fs::path src = fs::u8path(src_path);
    std::error_code sc_ec;
    if (!fs::exists(src, sc_ec)) {
      return false;
    }
    const fs::path dst = project_root / "capture" / dst_name;
    fs::rename(src, dst, sc_ec);
    if (sc_ec) {
      sc_ec.clear();
      fs::copy_file(src, dst, fs::copy_options::overwrite_existing, sc_ec);
      if (!sc_ec) {
        fs::remove(src, sc_ec);
        sc_ec.clear();
      }
    }
    return fs::exists(dst, sc_ec);
  };
  effective.mic_audio_enabled = false;
  if (input.mic_audio_enabled && !input.mic_audio_path.empty()) {
    effective.mic_audio_enabled =
        bundle_audio_sidecar(input.mic_audio_path, "mic.m4a");
  }
  effective.system_audio_enabled = false;
  if (input.system_audio_enabled && !input.system_audio_path.empty()) {
    effective.system_audio_enabled =
        bundle_audio_sidecar(input.system_audio_path, "system.m4a");
  }

  // Phase 10.4: by this point the screen video has been moved INTO the
  // bundle (the %TEMP% original is gone), so a failure below would strand a
  // half-built bundle with no usable manifest — invisible to the recovery
  // sweep and unopenable forever. Before returning such an error, make a
  // best-effort attempt to stamp the bundle `status: "failed"` so it at
  // least becomes a recognizable tombstone.
  const auto fail_with_rescue =
      [&](const std::string& message) -> ProjectWriterResult {
    ProjectWriterInput failed = effective;
    failed.status = "failed";
    WriteUtf8File(project_root / "project.json", BuildManifestJson(failed));
    return {ProjectWriterErrorKind::kFilesystem, message, {}};
  };

  // Write the three JSON files. We always overwrite (Phase 3E is the
  // first writer to ship; a partial earlier write should never persist).
  if (!WriteUtf8File(project_root / "project.json",
                     BuildManifestJson(effective))) {
    return fail_with_rescue("Failed to write project.json.");
  }
  if (!WriteUtf8File(project_root / "capture" / "screen.meta.json",
                     BuildScreenMetaJson(effective))) {
    return fail_with_rescue("Failed to write capture/screen.meta.json.");
  }
  // post/state.json placeholder for Phase 6+'s post-processing
  // pipeline. The empty `{}` body is enough to satisfy the manifest
  // pointer; the Dart side reads this lazily.
  if (!WriteUtf8File(project_root / "post" / "state.json", std::string("{}\n"))) {
    return fail_with_rescue("Failed to write post/state.json.");
  }

  ProjectWriterResult ok;
  ok.kind = ProjectWriterErrorKind::kNone;
  ok.project_path = project_root.u8string();
  // Phase 10.4 (review fix): report sidecar downgrades so the engine knows
  // the leftover temp is NOT a deletable straggler.
  ok.cursor_downgraded = input.cursor_enabled && !effective.cursor_enabled;
  ok.camera_downgraded = input.camera_enabled && !effective.camera_enabled;
  ok.mic_audio_downgraded =
      input.mic_audio_enabled && !effective.mic_audio_enabled;
  ok.system_audio_downgraded =
      input.system_audio_enabled && !effective.system_audio_enabled;
  return ok;
}

ProjectWriterResult WriteProvisionalProject(
    const ProvisionalProjectInput& input) {
  if (input.session_id.empty()) {
    return {ProjectWriterErrorKind::kBadInput,
            "session_id is required for the provisional project writer.",
            {}};
  }

  const std::string root = input.recordings_root_override.empty()
                                ? ResolveDefaultRecordingsRoot()
                                : input.recordings_root_override;

  std::error_code ec;
  // UTF-8 decode — see the matching comment in WriteRecordingProject.
  fs::path project_root =
      fs::u8path(root) / (input.session_id + ".clingfyproj");
  fs::create_directories(project_root, ec);
  if (ec) {
    return {ProjectWriterErrorKind::kFilesystem,
            "Failed to create provisional project root: " + ec.message(),
            {}};
  }

  ProjectWriterInput manifest_input;
  manifest_input.session_id = input.session_id;
  manifest_input.created_at_iso8601 = input.created_at_iso8601;
  manifest_input.status = "capturing";
#ifdef _WIN32
  manifest_input.owner_pid =
      input.owner_pid != 0 ? input.owner_pid : ::GetCurrentProcessId();
#else
  manifest_input.owner_pid = input.owner_pid;
#endif

  if (!WriteUtf8File(project_root / "project.json",
                     BuildManifestJson(manifest_input))) {
    return {ProjectWriterErrorKind::kFilesystem,
            "Failed to write provisional project.json.", {}};
  }

  ProjectWriterResult ok;
  ok.kind = ProjectWriterErrorKind::kNone;
  ok.project_path = project_root.u8string();
  return ok;
}

}  // namespace clingfy::capture
