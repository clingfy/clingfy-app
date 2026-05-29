#include "Bridge/Routers/storage_router.h"

#include <windows.h>

#include "Bridge/result_helpers.h"
#include "Services/save_folder.h"

namespace clingfy::bridge::routers::storage {

namespace {

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
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

void HandleNullString(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Returning null tells the settings UI "there is no persisted save folder"
  // -- Dart then falls back to its default path resolver.
  reply::Null(*result);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["getSaveFolder"] = &HandleGetSaveFolder;
  table["chooseSaveFolder"] = &HandleChooseSaveFolder;
  table["resetSaveFolder"] = &HandleResetSaveFolder;
  // openSaveFolder still a no-op: the chosen folder is persisted on the
  // Dart side, so opening "the" folder needs Dart to pass a path. Tracked
  // as a follow-up (open-folder-after-export). It is harmless today —
  // Dart treats the null reply as "nothing opened".
  table["openSaveFolder"] = &HandleNoopSetter;

  table["getTodayLogFilePath"] = &HandleNullString;
  table["revealTodayLogFile"] = &HandleNoopSetter;
  table["revealLogsFolder"] = &HandleNoopSetter;
  table["revealRecordingsFolder"] = &HandleNoopSetter;
  table["revealTempFolder"] = &HandleNoopSetter;
  table["revealFile"] = &HandleNoopSetter;

  table["clearCachedRecordings"] = &HandleClearCachedRecordings;
  table["getStorageSnapshot"] = &HandleGetStorageSnapshot;
}

}  // namespace clingfy::bridge::routers::storage
