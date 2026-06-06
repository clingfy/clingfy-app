#include "Capture/recording_project_writer.h"

#include <windows.h>
#include <shlobj.h>

#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
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
  // `status:"ready"` is the only value Dart will open — see
  // `RecordingProjectManifestError.projectStatusNotOpenable`.
  out << "  \"status\": \"ready\",\n";
  out << "  \"capture\": {\n";
  out << "    \"screenVideo\": \"capture/screen.mov\",\n";
  out << "    \"screenMetadata\": \"capture/screen.meta.json\",\n";
  out << "    \"cursorData\": \"capture/cursor.json\",\n";
  out << "    \"zoomManual\": \"capture/zoom.manual.json\"\n";
  out << "  },\n";
  out << "  \"camera\": {\n";
  out << "    \"rawVideo\": \"camera/raw.mov\",\n";
  out << "    \"metadata\": \"camera/meta.json\",\n";
  out << "    \"segmentsDirectory\": \"camera/segments\"\n";
  out << "  },\n";
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
  fs::path project_root =
      fs::path(root) / (input.session_id + ".clingfyproj");
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

  // Write the three JSON files. We always overwrite (Phase 3E is the
  // first writer to ship; a partial earlier write should never persist).
  if (!WriteUtf8File(project_root / "project.json",
                     BuildManifestJson(input))) {
    return {ProjectWriterErrorKind::kFilesystem,
            "Failed to write project.json.", {}};
  }
  if (!WriteUtf8File(project_root / "capture" / "screen.meta.json",
                     BuildScreenMetaJson(input))) {
    return {ProjectWriterErrorKind::kFilesystem,
            "Failed to write capture/screen.meta.json.", {}};
  }
  // post/state.json placeholder for Phase 6+'s post-processing
  // pipeline. The empty `{}` body is enough to satisfy the manifest
  // pointer; the Dart side reads this lazily.
  if (!WriteUtf8File(project_root / "post" / "state.json", std::string("{}\n"))) {
    return {ProjectWriterErrorKind::kFilesystem,
            "Failed to write post/state.json.", {}};
  }

  return {ProjectWriterErrorKind::kNone, {}, project_root.string()};
}

}  // namespace clingfy::capture
