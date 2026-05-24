#include "Bridge/Routers/misc_router.h"

#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::misc {

namespace {

void HandleNull(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

void HandleFalse(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Bool(*result, false);
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["pickImage"] = &HandleNull;
  table["cacheLocalizedStrings"] = &HandleNull;
  table["checkForUpdates"] = &HandleFalse;
}

}  // namespace clingfy::bridge::routers::misc
