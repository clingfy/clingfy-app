/// Phase 10.6 — Windows update feed URL composition (D2's "Dart handoff"
/// half: the feed URL travels as a `checkForUpdates` argument instead of a
/// CMake define, because the per-channel Front Door domain is already a
/// dart-define via `--dart-define-from-file`).
///
/// The release pipeline (ops/release/windows/04_publish.ps1) publishes
/// `latest-windows.json` under `downloads/windows/` on the channel's public
/// host. Dev and prod builds carry different hosts in their .env files, which
/// is what keeps a dev build from ever seeing the prod feed.
library;

/// The channel's public host + path prefix, e.g. `clingfy.com/updates` on prod
/// and `dev.clingfy.com/updates` on dev. Empty when the build ran without the
/// .env defines (bare `flutter test`, fresh clones).
///
/// Reads the provider-neutral key first and falls back to the historical
/// AZ_CDN_ENDPOINT. That fallback is the whole safety of this rename: this value
/// is COMPILED INTO THE INSTALLER, and a build that saw neither key would
/// produce an empty host, which windowsUpdateFeedUrl() turns into a null feed
/// URL -- an installer whose update check can never succeed, shipped by a lane
/// that still goes green. Nesting the old key as the default means the code can
/// land before, after, or between the .env changes and always resolve.
///
/// Remove the fallback only once both .env files and both ENV_*_B64 secrets
/// carry CLINGFY_UPDATE_FEED_HOST, and a Windows build has been confirmed to
/// report the right feed URL.
const String windowsUpdateCdnEndpointDefine = String.fromEnvironment(
  'CLINGFY_UPDATE_FEED_HOST',
  defaultValue: String.fromEnvironment('AZ_CDN_ENDPOINT', defaultValue: ''),
);

/// This build's release channel, matched against the feed's `channel`
/// field by the native check. Mirrors BuildConfig.appEnv (which lives in
/// lib/app and cannot be imported from core).
const String windowsUpdateChannelDefine = String.fromEnvironment(
  'APP_ENV',
  defaultValue: 'dev',
);

/// Joins a Front Door domain into the canonical feed URL. Accepts a bare
/// domain or one already carrying a scheme; trailing slashes are stripped.
/// Returns null when the endpoint is empty (feed not configured).
String? windowsUpdateFeedUrl({required String cdnEndpoint}) {
  var endpoint = cdnEndpoint.trim();
  if (endpoint.startsWith('https://')) {
    endpoint = endpoint.substring('https://'.length);
  } else if (endpoint.startsWith('http://')) {
    endpoint = endpoint.substring('http://'.length);
  }
  while (endpoint.endsWith('/')) {
    endpoint = endpoint.substring(0, endpoint.length - 1);
  }
  if (endpoint.isEmpty) {
    return null;
  }
  return 'https://$endpoint/downloads/windows/latest-windows.json';
}

/// The feed URL for this build, or null when no feed host was
/// provided at build time.
String? defaultWindowsUpdateFeedUrl() =>
    windowsUpdateFeedUrl(cdnEndpoint: windowsUpdateCdnEndpointDefine);
