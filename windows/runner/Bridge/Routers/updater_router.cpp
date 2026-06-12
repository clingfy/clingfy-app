#include "Bridge/Routers/updater_router.h"

#include <string>

#include "Bridge/result_helpers.h"
#include "Bridge/updater_event_publisher.h"
#include "Updater/update_checker.h"
#include "Updater/update_feed.h"

namespace clingfy::bridge::routers::updater {

namespace {

std::string ReadStringArg(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    const char* key) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return std::string{};
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return std::string{};
  }
  const auto* value = std::get_if<std::string>(&it->second);
  return value != nullptr ? *value : std::string{};
}

// Args (Windows-only; macOS ignores arguments entirely and lets Sparkle own
// the feed): { feedUrl: "https://.../latest-windows.json", channel: "dev" }.
// Dart fills feedUrl from the AZ_CDN_ENDPOINT dart-define; a build without
// the define sends no args and gets an honest false + updateError event
// instead of a silent no-op (the 10.3 "never silent-false" rule).
void HandleCheckForUpdates(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string feed_url = ReadStringArg(call, "feedUrl");
  const std::string channel = ReadStringArg(call, "channel");
  if (feed_url.empty()) {
    UpdaterEventPublisher::Instance().EmitUpdateError(
        clingfy::updater::codes::kFeedNotConfigured,
        "No update feed URL is configured for this build.");
    reply::Bool(*result, false);
    return;
  }
  reply::Bool(*result, clingfy::updater::StartUpdateCheck(feed_url, channel));
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["checkForUpdates"] = &HandleCheckForUpdates;
}

}  // namespace clingfy::bridge::routers::updater
