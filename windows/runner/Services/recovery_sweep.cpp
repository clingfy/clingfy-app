#include "Services/recovery_sweep.h"

#ifdef _WIN32
#include <windows.h>
#endif

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <fstream>
#include <sstream>
#include <unordered_set>

#include "Bridge/native_log_publisher.h"
#include "Capture/recording_project_reader.h"
#include "Capture/recording_project_writer.h"
#include "Encoding/encoder_output_path.h"

namespace clingfy::services {

namespace {

namespace fs = std::filesystem;

bool ReadEntireFile(const fs::path& path, std::string& out) {
  std::ifstream in(path, std::ios::binary);
  if (!in.is_open()) return false;
  std::ostringstream buffer;
  buffer << in.rdbuf();
  out = buffer.str();
  return true;
}

bool WriteUtf8File(const fs::path& path, const std::string& contents) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out.is_open()) return false;
  out.write(contents.data(), static_cast<std::streamsize>(contents.size()));
  return out.good();
}

// Real liveness probe. Fails SAFE: any PID we cannot positively prove dead
// or non-Clingfy is reported live, so the sweep never destroys a recording
// it can't reason about.
bool DefaultPidIsLiveClingfy(std::uint32_t pid) {
#ifdef _WIN32
  HANDLE handle = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                static_cast<DWORD>(pid));
  if (handle == nullptr) {
    // ERROR_INVALID_PARAMETER => no such process => provably dead.
    // Anything else (notably access denied) => something lives there that
    // we can't inspect => treat as live.
    return ::GetLastError() != ERROR_INVALID_PARAMETER;
  }
  DWORD exit_code = 0;
  const bool alive =
      ::GetExitCodeProcess(handle, &exit_code) && exit_code == STILL_ACTIVE;
  bool is_clingfy = true;  // fail safe if the image name is unreadable
  if (alive) {
    wchar_t image[MAX_PATH] = {};
    DWORD len = MAX_PATH;
    if (::QueryFullProcessImageNameW(handle, 0, image, &len) && len > 0) {
      std::wstring image_path(image, len);
      const size_t slash = image_path.find_last_of(L"\\/");
      std::wstring base = slash == std::wstring::npos
                              ? image_path
                              : image_path.substr(slash + 1);
      std::transform(base.begin(), base.end(), base.begin(), ::towlower);
      // PID reuse by an unrelated process => not our crashed instance.
      is_clingfy = base.find(L"clingfy") != std::wstring::npos;
    }
  }
  ::CloseHandle(handle);
  return alive && is_clingfy;
#else
  (void)pid;
  return false;
#endif
}

std::string ResolveTempDir(const std::string& override_dir) {
  if (!override_dir.empty()) return override_dir;
  std::error_code ec;
  const fs::path temp = fs::temp_directory_path(ec);
  if (ec) return {};
  return temp.string();
}

// The temp artifacts a session leaves while recording — exact names,
// derived the same way the encoder/sampler/sidecar writers derived them.
void InsertSessionTempNames(const std::string& session_id,
                            std::unordered_set<std::string>& names) {
  const std::string sanitized =
      clingfy::encoding::SanitizeSessionId(session_id);
  names.insert("clingfy_" + sanitized + ".mp4");
  names.insert("clingfy_" + sanitized + ".cursor.jsonl");
  names.insert("clingfy_" + sanitized + ".camera.mp4");
  // Audio separation: the mic / system sidecar temps (bundled into
  // capture/mic.m4a / capture/system.m4a on a clean stop).
  names.insert("clingfy_" + sanitized + ".mic.mp4");
  names.insert("clingfy_" + sanitized + ".sys.mp4");
}

}  // namespace

std::optional<std::string> ReplaceJsonStringValue(const std::string& json,
                                                  const std::string& key,
                                                  const std::string& value) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = 0;
  while (pos < json.size()) {
    pos = json.find(needle, pos);
    if (pos == std::string::npos) return std::nullopt;
    // A backslash immediately before the opening quote means this is an
    // escaped quote inside some string VALUE, not a real key.
    if (pos > 0 && json[pos - 1] == '\\') {
      pos += needle.size();
      continue;
    }
    // Review fix: a candidate NOT followed by `: "<string>"` is a
    // key-shaped string VALUE (e.g. `"displayName": "status"` — the value
    // bytes match the needle exactly). RESUME the scan instead of
    // aborting, or one lookalike ahead of the real key would silently
    // disable every failure-stamping path that rides on this helper.
    size_t cursor = pos + needle.size();
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor]))) {
      ++cursor;
    }
    if (cursor >= json.size() || json[cursor] != ':') {
      pos += needle.size();
      continue;
    }
    ++cursor;
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor]))) {
      ++cursor;
    }
    if (cursor >= json.size() || json[cursor] != '"') {
      pos += needle.size();
      continue;
    }
    const size_t value_start = ++cursor;
    while (cursor < json.size()) {
      if (json[cursor] == '\\') {
        cursor += 2;
        continue;
      }
      if (json[cursor] == '"') break;
      ++cursor;
    }
    if (cursor >= json.size() || json[cursor] != '"') return std::nullopt;
    return json.substr(0, value_start) + value + json.substr(cursor);
  }
  return std::nullopt;
}

bool BundleOwnedByLiveProcess(
    const std::filesystem::path& bundle_path, std::uint32_t self_pid,
    const std::function<bool(std::uint32_t)>& pid_is_live_clingfy) {
#ifdef _WIN32
  if (self_pid == 0) self_pid = ::GetCurrentProcessId();
#endif
  std::string manifest_text;
  if (!ReadEntireFile(bundle_path / "project.json", manifest_text)) {
    return false;
  }
  const capture::ManifestStatusProbe probe =
      capture::ProbeManifestStatus(manifest_text);
  if (!probe.parsed) return false;
  if (probe.status != "capturing" && probe.status != "finalizing") {
    return false;
  }
  if (probe.owner_pid == 0 || probe.owner_pid == self_pid) return false;
  return pid_is_live_clingfy ? pid_is_live_clingfy(probe.owner_pid)
                             : DefaultPidIsLiveClingfy(probe.owner_pid);
}

RecoverySweepResult RunRecoverySweep(const RecoverySweepOptions& options) {
  RecoverySweepResult result;

  const std::string root_str =
      options.recordings_root.empty()
          ? clingfy::capture::ResolveDefaultRecordingsRoot()
          : options.recordings_root;
  std::uint32_t self_pid = options.current_pid;
#ifdef _WIN32
  if (self_pid == 0) self_pid = ::GetCurrentProcessId();
#endif
  const auto pid_is_live = options.pid_is_live_clingfy
                               ? options.pid_is_live_clingfy
                               : DefaultPidIsLiveClingfy;

  // Temp names owned by a LIVE capturing session (never delete) vs by a
  // session we just proved dead (delete regardless of age — the owner is
  // gone, the unfinalized MP4 has no moov atom and can never be played).
  std::unordered_set<std::string> live_temp_names;
  std::unordered_set<std::string> dead_temp_names;

  std::error_code ec;
  const fs::path root = fs::u8path(root_str);
  if (!root_str.empty() && fs::exists(root, ec) &&
      fs::is_directory(root, ec)) {
    fs::directory_iterator it(
        root, fs::directory_options::skip_permission_denied, ec);
    const fs::directory_iterator end;
    for (; !ec && it != end; it.increment(ec)) {
      if (options.cancel != nullptr && options.cancel->load()) break;
      std::error_code entry_ec;
      if (!it->is_directory(entry_ec)) continue;
      const fs::path bundle = it->path();
      if (bundle.extension() != ".clingfyproj") continue;

      std::string manifest_text;
      if (!ReadEntireFile(bundle / "project.json", manifest_text)) continue;
      const capture::ManifestStatusProbe probe =
          capture::ProbeManifestStatus(manifest_text);
      if (!probe.parsed) continue;

      const std::string session_id = !probe.project_id.empty()
                                         ? probe.project_id
                                         : bundle.stem().string();

      // Review fix (blocker): ANY bundle that is not a dead in-flight one
      // PROTECTS its session's temp files. The engine deliberately keeps a
      // finalized, PLAYABLE screen/camera temp when bundling fails and
      // stamps the bundle "failed" — deleting those as "ownerless strands"
      // on the next launch would silently destroy the only copy of the
      // user's recording. The cost is retaining some moov-less garbage
      // next to old failed tombstones; deleting the bundle
      // (clearCachedRecordings) orphans its temps and they age out on the
      // following launch.
      if (probe.status != "capturing" && probe.status != "finalizing") {
        InsertSessionTempNames(session_id, live_temp_names);
        continue;
      }

      // Review fix (major): our own PID counts as LIVE, full stop. A
      // capturing bundle claiming our pid is either a recording that
      // started while this sweep walked the disk — marking it failed and
      // reporting it "interrupted" would be flatly wrong, and the manifest
      // rewrite would race Stop's — or a PID-reuse leftover from a crashed
      // instance, which the NEXT launch (different pid) sweeps normally.
      const bool owner_live =
          probe.owner_pid != 0 &&
          (probe.owner_pid == self_pid || pid_is_live(probe.owner_pid));
      if (owner_live) {
        InsertSessionTempNames(session_id, live_temp_names);
        continue;
      }

      // Owner is provably dead (or unidentifiable) — mark the bundle
      // failed. Rewrite failure is non-fatal: the next launch retries.
      // The dead session's temps are deletable regardless of age: the
      // owner died mid-capture, so the screen MP4 has no moov atom.
      bool marked = false;
      if (const auto rewritten =
              ReplaceJsonStringValue(manifest_text, "status", "failed");
          rewritten) {
        marked = WriteUtf8File(bundle / "project.json", *rewritten);
      }
      if (marked) {
        result.interrupted.push_back({bundle.string(), session_id});
      }
      InsertSessionTempNames(session_id, dead_temp_names);
    }
  }

  // --- Temp sweep -------------------------------------------------------
  const std::string temp_str = ResolveTempDir(options.temp_dir);
  const fs::path temp_root = fs::u8path(temp_str);
  std::error_code temp_ec;
  if (!temp_str.empty() && fs::exists(temp_root, temp_ec) &&
      fs::is_directory(temp_root, temp_ec)) {
    const auto now = options.now.has_value()
                         ? *options.now
                         : fs::file_time_type::clock::now();
    fs::directory_iterator it(
        temp_root, fs::directory_options::skip_permission_denied, temp_ec);
    const fs::directory_iterator end;
    for (; !temp_ec && it != end; it.increment(temp_ec)) {
      if (options.cancel != nullptr && options.cancel->load()) break;
      std::error_code entry_ec;
      if (!it->is_regular_file(entry_ec)) continue;
      const std::string name = it->path().filename().string();
      // Underscore prefix — the diagnostics zips are `clingfy-…` (dash) and
      // must never match.
      if (name.rfind("clingfy_", 0) != 0) continue;
      if (live_temp_names.count(name) != 0) continue;

      if (dead_temp_names.count(name) == 0) {
        // Ownerless strand (pre-10.4 build, or a manifest we failed to
        // read). A LIVE pre-10.4 recorder in another instance writes its
        // files continuously, so a generous age guard is what keeps this
        // deletion safe.
        const auto mtime = it->last_write_time(entry_ec);
        if (entry_ec) continue;
        if (now - mtime < options.min_temp_age) continue;
      }

      std::uint64_t size = 0;
      if (const auto file_size = it->file_size(entry_ec); !entry_ec) {
        size = static_cast<std::uint64_t>(file_size);
      }
      std::error_code remove_ec;
      if (fs::remove(it->path(), remove_ec) && !remove_ec) {
        ++result.cleaned_temp_files;
        result.cleaned_temp_bytes += size;
      }
    }
  }

  if (!result.interrupted.empty() || result.cleaned_temp_files > 0) {
    std::ostringstream line;
    line << "recovery sweep: " << result.interrupted.size()
         << " interrupted project(s) marked failed, "
         << result.cleaned_temp_files << " stranded temp file(s) removed ("
         << result.cleaned_temp_bytes << " bytes)";
    clingfy::bridge::NativeLogPublisher::Instance().Warn("Recording",
                                                         line.str());
  }
  return result;
}

}  // namespace clingfy::services
