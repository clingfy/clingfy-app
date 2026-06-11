#include "Bridge/Routers/storage_router.h"

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <system_error>
#include <vector>

#include "Bridge/result_helpers.h"
#include "Capture/recording_engine.h"
#include "Capture/recording_project_writer.h"
#include "Services/log_locations.h"
#include "Services/recovery_sweep.h"
#include "Services/save_folder.h"
#include "Services/shell_reveal.h"

namespace clingfy::bridge::routers::storage {

namespace {

namespace fs = std::filesystem;

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

bool ExistsDir(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  std::error_code ec;
  return fs::is_directory(fs::path(path), ec);
}

bool ExistsFile(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  std::error_code ec;
  return fs::is_regular_file(fs::path(path), ec);
}

// %TEMP% — where in-flight recordings (`clingfy_<id>.*`) live.
std::wstring TempRoot() {
  wchar_t buf[MAX_PATH + 1] = {};
  const DWORD len = ::GetTempPathW(MAX_PATH + 1, buf);
  if (len == 0 || len > MAX_PATH) {
    return {};
  }
  return std::wstring(buf, len);
}

// Return the default export folder (%USERPROFILE%\Videos\Clingfy) as the
// first-run seed. Dart persists whatever it gets in SharedPreferences, so
// `getSaveFolder` is only consulted when no folder is cached yet. We do
// NOT create the folder here — creation is lazy, on first export, matching
// the macOS SaveFolderStore which returns ~/Movies/Clingfy without
// touching disk.
void HandleGetSaveFolder(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string folder = clingfy::storage::DefaultSaveFolderUtf8();
  if (folder.empty()) {
    reply::Null(*result);
  } else {
    reply::String(*result, folder);
  }
}

// Show the native folder picker. Returns the chosen path, or null on
// cancel — `WorkspaceSettingsController.chooseSaveFolderPath` treats null
// as "user cancelled" and keeps the previous folder.
void HandleChooseSaveFolder(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto chosen =
      clingfy::storage::ChooseSaveFolderDialog(::GetActiveWindow());
  if (chosen.has_value() && !chosen->empty()) {
    reply::String(*result, *chosen);
  } else {
    reply::Null(*result);
  }
}

// Reset to the default folder. Dart re-caches whatever comes back.
void HandleResetSaveFolder(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string folder = clingfy::storage::DefaultSaveFolderUtf8();
  if (folder.empty()) {
    reply::Null(*result);
  } else {
    reply::String(*result, folder);
  }
}

// ---- Phase 10.3: real storage snapshot + cached-recordings clear -----------
//
// The zero-filled snapshot made the storage dashboard show "Healthy /
// 0 B everywhere" and kept the recording-start storage preflight from ever
// firing — a lying pane. Thresholds mirror macOS StorageInfoProvider
// (warning = 20 GiB, critical = 10 GiB free).

constexpr int64_t kStorageWarningThresholdBytes =
    int64_t{20} * 1024 * 1024 * 1024;
constexpr int64_t kStorageCriticalThresholdBytes =
    int64_t{10} * 1024 * 1024 * 1024;

// Recursive byte total of a directory tree. Best-effort: unreadable
// entries are skipped, a missing dir is 0.
int64_t DirectoryTreeBytes(const std::wstring& dir) {
  if (dir.empty()) {
    return 0;
  }
  std::error_code ec;
  if (!fs::is_directory(fs::path(dir), ec)) {
    return 0;
  }
  int64_t total = 0;
  fs::recursive_directory_iterator it(
      fs::path(dir), fs::directory_options::skip_permission_denied, ec);
  if (ec) {
    return 0;
  }
  for (auto end = fs::recursive_directory_iterator(); it != end;
       it.increment(ec)) {
    if (ec) {
      break;
    }
    std::error_code entry_ec;
    if (it->is_regular_file(entry_ec)) {
      const auto size = it->file_size(entry_ec);
      if (!entry_ec) {
        total += static_cast<int64_t>(size);
      }
    }
  }
  return total;
}

// Byte total of clingfy_* files directly under %TEMP% — the in-flight /
// stranded recording namespace (same prefix the 10.1 orphan scan watches).
int64_t ClingfyTempBytes(const std::wstring& temp_dir) {
  if (temp_dir.empty()) {
    return 0;
  }
  std::error_code ec;
  int64_t total = 0;
  fs::directory_iterator it(fs::path(temp_dir), ec);
  if (ec) {
    return 0;
  }
  // increment(ec): the range-for operator++ throws on FindNextFileW
  // failure, which would escape the dispatch path and kill the runner.
  for (auto end = fs::directory_iterator(); it != end; it.increment(ec)) {
    if (ec) {
      break;
    }
    std::error_code entry_ec;
    if (!it->is_regular_file(entry_ec)) {
      continue;
    }
    if (it->path().filename().wstring().rfind(L"clingfy_", 0) != 0) {
      continue;
    }
    const auto size = it->file_size(entry_ec);
    if (!entry_ec) {
      total += static_cast<int64_t>(size);
    }
  }
  return total;
}

// Deletes the project BUNDLES under the recordings root — the Windows
// analogue of macOS RecordingStore.deleteAll() (internal recording copies,
// never exported files). Only `*.clingfyproj` directories qualify, exactly
// like macOS's isProjectDirectory extension filter — deleting arbitrary
// subdirectories would turn a stale CLINGFY_RECORDINGS_ROOT override (or
// any foreign folder a user drops into the root) into unbounded recursive
// deletion. Returns the number of bundles removed.
int HandleClearProjects(const std::wstring& recordings_root) {
  if (recordings_root.empty()) {
    return 0;
  }
  std::error_code ec;
  fs::directory_iterator it(fs::path(recordings_root), ec);
  if (ec) {
    return 0;
  }
  int deleted = 0;
  // Collect first: removing while iterating invalidates the iterator.
  // increment(ec) — the range-for operator++ THROWS on enumeration
  // failure, which would escape the dispatch path and kill the runner.
  std::vector<fs::path> projects;
  for (auto end = fs::directory_iterator(); it != end; it.increment(ec)) {
    if (ec) {
      break;
    }
    std::error_code entry_ec;
    if (it->is_directory(entry_ec) &&
        it->path().extension() == L".clingfyproj") {
      // Phase 10.4: dev + prod share the recordings root until 10.5 splits
      // installer identities — the engine's IsSessionActive guard only
      // covers THIS process. Skip a bundle that a live sibling Clingfy
      // process is capturing into right now.
      if (clingfy::services::BundleOwnedByLiveProcess(it->path())) {
        continue;
      }
      projects.push_back(it->path());
    }
  }
  for (const auto& project : projects) {
    std::error_code remove_ec;
    fs::remove_all(project, remove_ec);
    if (!remove_ec) {
      ++deleted;
    }
  }
  return deleted;
}

void HandleClearCachedRecordings(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // macOS parity: refuse while a recording is in flight (its project is
  // about to be written into the root we'd be deleting).
  if (clingfy::capture::RecordingEngine::Instance().IsSessionActive()) {
    result->Error("RECORDINGS_IN_USE",
                  "Cached recordings cannot be cleared while recording is "
                  "active.");
    return;
  }
  const std::wstring root = clingfy::storage::Utf8ToWide(
      clingfy::capture::ResolveDefaultRecordingsRoot());
  const int deleted = HandleClearProjects(root);
  flutter::EncodableMap value{
      {flutter::EncodableValue("deletedCount"),
       flutter::EncodableValue(deleted)},
  };
  reply::Map(*result, std::move(value));
}

void HandleGetStorageSnapshot(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string recordings_root_utf8 =
      clingfy::capture::ResolveDefaultRecordingsRoot();
  const std::wstring recordings_root =
      clingfy::storage::Utf8ToWide(recordings_root_utf8);
  const std::wstring temp = TempRoot();
  const std::wstring native_logs = clingfy::storage::NativeLogsDirectory();
  const std::wstring dart_logs = clingfy::storage::DartLogsDirectory();

  // Free/total space on the volume that holds the recordings root (which is
  // also where %TEMP% in-flight files land on a default install). Falls
  // back to the temp volume when the recordings root drive is unresolvable.
  ULARGE_INTEGER free_to_caller{}, total{}, total_free{};
  BOOL disk_ok = FALSE;
  if (!recordings_root.empty()) {
    disk_ok = ::GetDiskFreeSpaceExW(recordings_root.c_str(), &free_to_caller,
                                    &total, &total_free);
    if (!disk_ok) {
      // The root may not exist yet on a fresh install — query its drive.
      const std::wstring drive =
          fs::path(recordings_root).root_path().wstring();
      if (!drive.empty()) {
        disk_ok = ::GetDiskFreeSpaceExW(drive.c_str(), &free_to_caller,
                                        &total, &total_free);
      }
    }
  }
  if (!disk_ok && !temp.empty()) {
    disk_ok = ::GetDiskFreeSpaceExW(temp.c_str(), &free_to_caller, &total,
                                    &total_free);
  }

  const int64_t system_total =
      disk_ok ? static_cast<int64_t>(total.QuadPart) : 0;
  const int64_t system_available =
      disk_ok ? static_cast<int64_t>(free_to_caller.QuadPart) : 0;

  flutter::EncodableMap value{
      {flutter::EncodableValue("systemTotalBytes"),
       flutter::EncodableValue(system_total)},
      {flutter::EncodableValue("systemAvailableBytes"),
       flutter::EncodableValue(system_available)},
      {flutter::EncodableValue("recordingsBytes"),
       flutter::EncodableValue(DirectoryTreeBytes(recordings_root))},
      {flutter::EncodableValue("tempBytes"),
       flutter::EncodableValue(ClingfyTempBytes(temp))},
      {flutter::EncodableValue("logsBytes"),
       flutter::EncodableValue(DirectoryTreeBytes(native_logs) +
                               DirectoryTreeBytes(dart_logs))},
      {flutter::EncodableValue("recordingsPath"),
       flutter::EncodableValue(recordings_root_utf8)},
      {flutter::EncodableValue("tempPath"),
       flutter::EncodableValue(clingfy::storage::WideToUtf8(temp))},
      {flutter::EncodableValue("logsPath"),
       flutter::EncodableValue(clingfy::storage::WideToUtf8(native_logs))},
      {flutter::EncodableValue("warningThresholdBytes"),
       flutter::EncodableValue(kStorageWarningThresholdBytes)},
      {flutter::EncodableValue("criticalThresholdBytes"),
       flutter::EncodableValue(kStorageCriticalThresholdBytes)},
  };
  reply::Map(*result, std::move(value));
}

// Phase 10.1 — the log/reveal handlers below are real (they were silent
// no-ops; revealTodayLogFile even produced a fake success toast in the
// diagnostics settings). Error codes mirror the macOS MainFlutterWindow
// contract exactly so the shared Dart UI maps them to the same localized
// messages: LOG_FILE_UNAVAILABLE / LOG_FILE_NOT_FOUND /
// RECORDINGS_FOLDER_UNAVAILABLE / TEMP_FOLDER_UNAVAILABLE / FILE_NOT_FOUND.

void HandleGetTodayLogFilePath(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::wstring logs_dir = clingfy::storage::DartLogsDirectory();
  if (!ExistsDir(logs_dir)) {
    result->Error("LOG_FILE_UNAVAILABLE",
                  "Log storage directory is unavailable");
    return;
  }
  const std::wstring today = clingfy::storage::TodayDartLogFilePath();
  if (!ExistsFile(today)) {
    result->Error("LOG_FILE_NOT_FOUND", "Today's log file does not exist yet.");
    return;
  }
  reply::String(*result, clingfy::storage::WideToUtf8(today));
}

void HandleRevealTodayLogFile(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::wstring logs_dir = clingfy::storage::DartLogsDirectory();
  if (!ExistsDir(logs_dir)) {
    result->Error("LOG_FILE_UNAVAILABLE",
                  "Log storage directory is unavailable");
    return;
  }
  const std::wstring today = clingfy::storage::TodayDartLogFilePath();
  if (!ExistsFile(today)) {
    result->Error("LOG_FILE_NOT_FOUND", "Today's log file does not exist yet.");
    return;
  }
  clingfy::storage::SelectInExplorer(today);
  reply::Null(*result);
}

void HandleRevealLogsFolder(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::wstring logs_dir = clingfy::storage::DartLogsDirectory();
  if (!ExistsDir(logs_dir)) {
    result->Error("LOG_FILE_UNAVAILABLE",
                  "Log storage directory is unavailable");
    return;
  }
  clingfy::storage::OpenFolderInExplorer(logs_dir);
  reply::Null(*result);
}

void HandleRevealRecordingsFolder(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::wstring root = clingfy::storage::Utf8ToWide(
      clingfy::capture::ResolveDefaultRecordingsRoot());
  if (!ExistsDir(root)) {
    result->Error("RECORDINGS_FOLDER_UNAVAILABLE",
                  "Recordings storage directory is unavailable");
    return;
  }
  clingfy::storage::OpenFolderInExplorer(root);
  reply::Null(*result);
}

void HandleRevealTempFolder(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::wstring temp = TempRoot();
  if (!ExistsDir(temp)) {
    result->Error("TEMP_FOLDER_UNAVAILABLE",
                  "Temporary storage directory is unavailable");
    return;
  }
  clingfy::storage::OpenFolderInExplorer(temp);
  reply::Null(*result);
}

void HandleRevealFile(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  std::optional<std::string> path;
  if (args != nullptr) {
    path = ReadOptionalString(*args, "path");
  }
  if (!path.has_value()) {
    reply::BadArgs(*result, "revealFile requires a 'path' argument.");
    return;
  }
  const std::wstring wide = clingfy::storage::Utf8ToWide(*path);
  std::error_code ec;
  if (!fs::exists(fs::path(wide), ec)) {
    result->Error(error::kFileNotFound, "File not found");
    return;
  }
  // Files get select-in-folder; directories open directly.
  const auto action = clingfy::storage::ResolveRevealAction(
      true, fs::is_directory(fs::path(wide), ec));
  if (action == clingfy::storage::RevealAction::kOpenFolder) {
    clingfy::storage::OpenFolderInExplorer(wide);
  } else {
    clingfy::storage::SelectInExplorer(wide);
  }
  reply::Null(*result);
}

// Open the user's save folder. The chosen folder is persisted on the Dart
// side (SharedPreferences), so Dart passes it as an optional `path` arg —
// macOS ignores the extra argument (it persists the folder natively).
// Falls back to the default save folder when no path arrives.
void HandleOpenSaveFolder(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  std::optional<std::string> path;
  if (args != nullptr) {
    path = ReadOptionalString(*args, "path");
  }
  std::wstring folder = path.has_value()
                            ? clingfy::storage::Utf8ToWide(*path)
                            : clingfy::storage::DefaultSaveFolder();
  if (!ExistsDir(folder)) {
    // A customized-but-deleted folder still has the default to fall back to.
    folder = clingfy::storage::DefaultSaveFolder();
  }
  if (!ExistsDir(folder)) {
    result->Error("SAVE_FOLDER_UNAVAILABLE",
                  "Save folder is unavailable");
    return;
  }
  clingfy::storage::OpenFolderInExplorer(folder);
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["getSaveFolder"] = &HandleGetSaveFolder;
  table["chooseSaveFolder"] = &HandleChooseSaveFolder;
  table["resetSaveFolder"] = &HandleResetSaveFolder;
  table["openSaveFolder"] = &HandleOpenSaveFolder;

  table["getTodayLogFilePath"] = &HandleGetTodayLogFilePath;
  table["revealTodayLogFile"] = &HandleRevealTodayLogFile;
  table["revealLogsFolder"] = &HandleRevealLogsFolder;
  table["revealRecordingsFolder"] = &HandleRevealRecordingsFolder;
  table["revealTempFolder"] = &HandleRevealTempFolder;
  table["revealFile"] = &HandleRevealFile;

  table["clearCachedRecordings"] = &HandleClearCachedRecordings;
  table["getStorageSnapshot"] = &HandleGetStorageSnapshot;
}

}  // namespace clingfy::bridge::routers::storage
