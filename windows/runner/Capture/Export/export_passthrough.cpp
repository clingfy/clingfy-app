#include "Capture/Export/export_passthrough.h"

#include <windows.h>

#include <algorithm>
#include <filesystem>
#include <string>
#include <system_error>

#include "Capture/Export/export_geometry.h"
#include "Capture/Export/export_pipeline.h"
#include "Capture/recording_project_reader.h"

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
fs::path UniqueDestination(const fs::path& dir, const std::string& stem) {
  fs::path candidate = dir / (stem + ".mov");
  if (!fs::exists(candidate)) {
    return candidate;
  }
  for (int i = 1; i < 1000; ++i) {
    candidate = dir / (stem + " (" + std::to_string(i) + ").mov");
    if (!fs::exists(candidate)) {
      return candidate;
    }
  }
  // Pathological: 1000 collisions. Caller will surface the eventual
  // copy_file failure as kCopyFailed.
  return dir / (stem + " (overflow).mov");
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

}  // namespace

std::string ResolveExportDestination(const std::string& directory,
                                     const std::string& filename_stem) {
  const std::string trimmed_dir = Trim(directory);
  const std::string trimmed_stem = Trim(filename_stem);

  std::string stem = StripExtension(trimmed_stem);
  stem = SanitizeFilename(stem);
  if (stem.empty()) {
    stem = "Untitled";
  }

  fs::path dir_path = fs::u8path(trimmed_dir);
  fs::path candidate = UniqueDestination(dir_path, stem);
  return candidate.u8string();
}

PassthroughResult ExportPassthroughCopy(const PassthroughInput& input) {
  PassthroughResult out;

  const std::string project = Trim(input.project_path);
  if (project.empty()) {
    out.error = PassthroughError::kInputMissing;
    out.message = "exportVideo: projectPath is required but was empty.";
    return out;
  }

  const std::string dir = Trim(input.directory_override);
  if (dir.empty()) {
    out.error = PassthroughError::kNoDestination;
    out.message =
        "exportVideo: directoryOverride is required for Slice 1 — no default "
        "save folder is wired up yet.";
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

  // Compute the destination (collision-avoided, .mov-forced). Done
  // separately from the copy so the test can pin it without touching
  // the filesystem.
  const std::string destination_utf8 =
      ResolveExportDestination(dir, input.filename);
  const fs::path destination = fs::u8path(destination_utf8);

  // Ensure the destination directory exists. The user picked it via a
  // save-as dialog so it normally already does, but being defensive
  // here means `EXPORT_ERROR` reads "copy failed" rather than something
  // more confusing.
  std::error_code ec;
  fs::create_directories(destination.parent_path(), ec);

  if (IsIdentityTransform(input.layout, input.resolution)) {
    // Fast-path: layout=auto & resolution=auto means the output is
    // pixel-for-pixel the source, so copy it byte-for-byte. Lossless,
    // instant, and it keeps the original audio + container untouched —
    // no point decoding and re-encoding a recording into an identical
    // frame. `overwrite_existing` would race with `UniqueDestination`'s
    // collision avoidance so we deliberately omit it.
    fs::copy_file(source, destination, fs::copy_options::none, ec);
    if (ec) {
      out.error = PassthroughError::kCopyFailed;
      out.message =
          "exportVideo: copy_file failed (" + ec.message() +
          "); source=" + source.u8string() +
          " destination=" + destination.u8string();
      return out;
    }
  } else {
    // Composition path: decode the recording, composite each frame at the
    // requested resolution / layout / fit, and re-encode. Source audio is
    // carried through so the resized export is not silent (gain/normalize
    // is Slice 4).
    RenderRequest render;
    render.source_video_path = read.project->screen_path;
    render.destination_path = destination.u8string();
    render.layout = input.layout;
    render.resolution = input.resolution;
    render.fit = input.fit;
    render.fps_hint = read.project->metadata.has_value()
                          ? read.project->metadata->fps
                          : 0u;
    const RenderResult render_result = RenderComposedExport(render);
    if (!render_result.ok) {
      out.error = PassthroughError::kRenderFailed;
      out.message =
          "exportVideo: composition render failed — " + render_result.message;
      return out;
    }
  }

  out.output_path = destination.u8string();
  const std::string format_lower = [&] {
    std::string lo = input.format;
    std::transform(lo.begin(), lo.end(), lo.begin(),
                   [](unsigned char c) {
                     return static_cast<char>(std::tolower(c));
                   });
    return lo;
  }();
  // Treat empty / "mov" as honoring the request; anything else is a
  // soft downgrade Slice 5 will fix.
  out.format_was_downgraded =
      !format_lower.empty() && format_lower != "mov";
  return out;
}

}  // namespace clingfy::capture::export_
