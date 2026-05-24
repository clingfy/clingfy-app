#include "Bridge/Routers/storage_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::storage {

namespace {

void HandleNoopSetter(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
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
  table["getSaveFolder"] = &HandleNullString;
  table["chooseSaveFolder"] = &HandleNullString;
  table["resetSaveFolder"] = &HandleNullString;
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
