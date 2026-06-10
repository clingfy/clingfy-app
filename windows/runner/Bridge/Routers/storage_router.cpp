#include "Bridge/Routers/storage_router.h"

#include <windows.h>

#include <filesystem>
#include <optional>
#include <string>
#include <system_error>

#include "Bridge/result_helpers.h"
#include "Capture/recording_project_writer.h"
#include "Services/log_locations.h"
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

// `clearCachedRecordings` is documented to return `{deletedCount: N}`.
// Returning zero matches "no cached recordings cleared", which is true
// because there are no recordings yet.
void HandleClearCachedRecordings(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap value{
      {flutter::EncodableValue("deletedCount"), flutter::EncodableValue(0)},
  };
  reply::Map(*result, std::move(value));
}

// Zero-filled storage snapshot. `StorageSnapshot.fromMap` tolerates missing /
// zero values; the storage dashboard renders 0 B used and 0 B free until
// real KnownFolder-backed totals are implemented.
void HandleGetStorageSnapshot(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap value{
      {flutter::EncodableValue("systemTotalBytes"),
       flutter::EncodableValue(int64_t{0})},
      {flutter::EncodableValue("systemAvailableBytes"),
       flutter::EncodableValue(int64_t{0})},
      {flutter::EncodableValue("recordingsBytes"),
       flutter::EncodableValue(int64_t{0})},
      {flutter::EncodableValue("tempBytes"),
       flutter::EncodableValue(int64_t{0})},
      {flutter::EncodableValue("logsBytes"),
       flutter::EncodableValue(int64_t{0})},
      {flutter::EncodableValue("recordingsPath"),
       flutter::EncodableValue(std::string{})},
      {flutter::EncodableValue("tempPath"),
       flutter::EncodableValue(std::string{})},
      {flutter::EncodableValue("logsPath"),
       flutter::EncodableValue(std::string{})},
      {flutter::EncodableValue("warningThresholdBytes"),
       flutter::EncodableValue(int64_t{0})},
      {flutter::EncodableValue("criticalThresholdBytes"),
       flutter::EncodableValue(int64_t{0})},
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
