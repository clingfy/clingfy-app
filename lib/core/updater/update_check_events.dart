/// Phase 10.6 — typed events for the Windows update check.
///
/// The native side (windows/runner/Bridge/updater_event_publisher.cpp)
/// emits these on the `com.clingfy/updater/events` channel:
///
///   {type: 'checking'}
///   {type: 'updateAvailable', version, build, url, versionFull}
///   {type: 'noUpdateAvailable', version}
///   {type: 'updateError', code, message}
///
/// macOS Sparkle emits only `updateAvailable` (with version/build and no
/// url) and drives every other state through its own UI, so parsing here
/// is tolerant: missing keys become null and unknown types parse to null.
library;

/// Machine-readable `updateError` codes. Keep in sync with
/// `windows/runner/Updater/update_feed.h` (clingfy::updater::codes).
class UpdateCheckErrorCodes {
  UpdateCheckErrorCodes._();

  static const String feedNotConfigured = 'UPDATE_FEED_NOT_CONFIGURED';
  static const String feedUnreachable = 'UPDATE_FEED_UNREACHABLE';
  static const String feedMalformed = 'UPDATE_FEED_MALFORMED';
  static const String feedMismatch = 'UPDATE_FEED_MISMATCH';
  static const String urlMissing = 'UPDATE_URL_MISSING';
  static const String versionUnknown = 'UPDATE_CURRENT_VERSION_UNKNOWN';
}

enum UpdateCheckStatus { checking, updateAvailable, noUpdateAvailable, error }

class UpdateCheckEvent {
  const UpdateCheckEvent._({
    required this.status,
    this.version,
    this.build,
    this.url,
    this.versionFull,
    this.code,
    this.message,
  });

  final UpdateCheckStatus status;

  /// Advertised version ("1.0.5") for updateAvailable; the feed's latest
  /// published version for noUpdateAvailable.
  final String? version;

  /// Advertised build number, as a string (macOS Sparkle parity).
  final String? build;

  /// https installer download URL (Windows only).
  final String? url;

  /// "x.y.z+build" (Windows only).
  final String? versionFull;

  /// One of [UpdateCheckErrorCodes] when [status] is [UpdateCheckStatus.error].
  final String? code;

  /// Human-readable error detail, the fallback for unrecognized codes.
  final String? message;

  /// Returns null for unknown event types so future native additions are
  /// ignored instead of crashing the listener.
  static UpdateCheckEvent? fromMap(Map<String, dynamic> map) {
    String? str(String key) {
      final value = map[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    switch (map['type']) {
      case 'checking':
        return const UpdateCheckEvent._(status: UpdateCheckStatus.checking);
      case 'updateAvailable':
        return UpdateCheckEvent._(
          status: UpdateCheckStatus.updateAvailable,
          version: str('version'),
          build: str('build'),
          url: str('url'),
          versionFull: str('versionFull'),
        );
      case 'noUpdateAvailable':
        return UpdateCheckEvent._(
          status: UpdateCheckStatus.noUpdateAvailable,
          version: str('version'),
        );
      case 'updateError':
        return UpdateCheckEvent._(
          status: UpdateCheckStatus.error,
          code: str('code'),
          message: str('message'),
        );
      default:
        return null;
    }
  }
}
