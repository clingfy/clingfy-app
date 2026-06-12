#ifndef RUNNER_UPDATER_UPDATE_FEED_H_
#define RUNNER_UPDATER_UPDATE_FEED_H_

#include <cstdint>
#include <optional>
#include <string>

// Phase 10.6 — pure feed model for the private-beta update check (D2).
//
// The Windows release pipeline (ops/release/windows/04_publish_azure.ps1)
// publishes a static `latest-windows.json` per channel:
//
//   { "version": "1.0.4", "build": 5, "versionFull": "1.0.4+5",
//     "channel": "dev", "platform": "windows-x64",
//     "fileName": "Clingfy_Dev_Setup_1.0.4+5.exe",
//     "url": "https://<front-door>/downloads/windows/<fileName>",
//     "sha256": "...", "sizeBytes": 123, "minimumOsVersion": "10.0.18362",
//     "publishedAt": "2026-06-12T12:00:00Z" }
//
// Everything in this header is pure (no OS / network calls) so the parse +
// compare + decide pipeline is fully unit-testable. The feed body is
// REMOTE INPUT: parsing reuses the string- and depth-aware key scan from
// camera_meta.cpp so a key-shaped substring inside a value (e.g. a crafted
// fileName containing `"version":`) can never masquerade as a real key.
namespace clingfy::updater {

// Machine-readable error codes carried in the `updateError` event payload.
// Dart maps recognized codes to localized strings; unknown codes fall back
// to the raw message. Keep in sync with the constants in
// lib/core/updater/update_check_events.dart.
namespace codes {
inline constexpr char kFeedNotConfigured[] = "UPDATE_FEED_NOT_CONFIGURED";
inline constexpr char kFeedUnreachable[] = "UPDATE_FEED_UNREACHABLE";
inline constexpr char kFeedMalformed[] = "UPDATE_FEED_MALFORMED";
inline constexpr char kFeedMismatch[] = "UPDATE_FEED_MISMATCH";
inline constexpr char kUrlMissing[] = "UPDATE_URL_MISSING";
inline constexpr char kVersionUnknown[] = "UPDATE_CURRENT_VERSION_UNKNOWN";
}  // namespace codes

struct UpdateFeed {
  bool parsed = false;       // false -> body was not a JSON object
  std::string version;       // "1.0.4" (empty when missing)
  std::int64_t build = -1;   // -1 when missing
  std::string version_full;  // "1.0.4+5"
  std::string channel;       // "dev" / "prod" / "local"
  std::string platform;      // "windows-x64"
  std::string url;           // installer download URL
  std::string sha256;
  std::int64_t size_bytes = -1;
  std::string published_at;
};

// Tolerant top-level-key scan of the feed body. `parsed` is false when the
// trimmed body is not `{...}`; individual fields keep their defaults when
// missing or of the wrong shape.
UpdateFeed ParseUpdateFeed(const std::string& json);

// Makes a remote string safe to put on the event channel: invalid UTF-8
// sequences (lone continuation bytes, truncated/overlong sequences,
// surrogate encodings) become '?', and the result is capped at `max_len`
// bytes (never splitting a multi-byte character). Without this, a single
// invalid byte in the feed makes Dart's StandardMessageCodec decode throw
// and the whole event is silently dropped — the About UI would sit on
// "checking" forever.
std::string SanitizeForEvent(const std::string& input, size_t max_len = 512);

struct AppVersion {
  int major = 0;
  int minor = 0;
  int patch = 0;
  std::int64_t build = 0;
};

// "1.0.4" -> {1,0,4,0}. Rejects empty/extra/non-numeric segments and
// negative values. The build is NOT part of the version string (the feed
// carries it separately); callers fill it in afterwards.
std::optional<AppVersion> ParseVersionString(const std::string& version);

// True when `feed` is strictly newer: version tuple greater, or equal
// version tuple with a greater build number.
bool FeedIsNewer(const AppVersion& feed, const AppVersion& current);

struct UpdateDecision {
  enum class Action { kUpdateAvailable, kNoUpdate, kError };
  Action action = Action::kError;
  std::string code;     // codes::* when action == kError
  std::string message;  // human-readable detail when action == kError
};

// Decides what the check should report. Rules, in order:
//   * unparsed feed / unparsable feed version  -> kFeedMalformed
//   * feed platform present and != "windows-x64" -> kFeedMismatch
//   * expected_channel AND feed channel both non-empty and different
//     -> kFeedMismatch (the per-channel Front Door domains are the primary
//     isolation; this catches a mispublished feed)
//   * feed newer but url missing / not https  -> kUrlMissing
//   * feed newer                              -> kUpdateAvailable
//   * otherwise                               -> kNoUpdate
UpdateDecision EvaluateUpdateFeed(const UpdateFeed& feed,
                                  const std::string& expected_channel,
                                  const AppVersion& current);

}  // namespace clingfy::updater

#endif  // RUNNER_UPDATER_UPDATE_FEED_H_
