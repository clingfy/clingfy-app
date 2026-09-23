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
/// COMPILED INTO THE INSTALLER, and the only source for it. A build that does
/// not carry this define produces an empty host, which windowsUpdateFeedUrl()
/// turns into a null feed URL -- an installer whose update check can never
/// succeed, shipped by a lane that still reports success, because 05_smoke.ps1
/// verifies AWS_PUBLIC_ENDPOINT rather than the value inside the binary. Both
/// .env files and both ENV_*_B64 secrets must define it.
///
/// Until 2026-09-21 this fell back to AZ_CDN_ENDPOINT, the Azure-era name this
/// key was renamed from (8a4e3ca); #556 deleted the fallback. Nothing reads
/// AZ_CDN_ENDPOINT any more -- not this define, not the release scripts, where
/// the `azure` storage-provider arm is gone and _config.ps1's AzureLegacyKeys
/// load-only allowlist does not even name it. It is still IN both secrets
/// though: run 35609712749 (2026-09-21) printed it from both ENV_DEV_B64 and
/// ENV_PROD_B64. Gone from the vault .env files, not yet from the secrets.
const String windowsUpdateCdnEndpointDefine = String.fromEnvironment(
  'CLINGFY_UPDATE_FEED_HOST',
  defaultValue: '',
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
