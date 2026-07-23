import 'dart:convert';
import 'dart:io' show Platform;

import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Anonymous product analytics (PostHog, EU cloud) — the desktop counterpart of the websites'
/// integration. Static facade like [ClingfyTelemetry]; wired in [AppRunner.run].
///
/// The privacy/exclusion contract (clingfy-labs `docs/runbooks/analytics-posthog.md`) is enforced
/// HERE, not at call sites:
///  - `kDebugMode` runs capture NOTHING — developing the app never emits events;
///  - without a POSTHOG_TOKEN build define the service is a silent no-op (local builds send
///    nothing; the token is a public-class ingestion key, injected like SENTRY_DSN);
///  - the "Share anonymous usage analytics" setting turns it off entirely at runtime;
///  - `environment` derives from APP_ENV (dev builds land under `development`, filtered out of
///    every production dashboard);
///  - events stay anonymous: the distinct id is a random per-install UUID, person profiles are
///    suppressed (`$process_person_profile: false`), and forbidden keys (paths, titles, license
///    keys…) are stripped before anything leaves the machine.
///
/// Failures are swallowed — analytics must never break recording or export. No offline queue in
/// v1: an event that can't send right now is dropped (volume is a handful per session).
abstract final class ClingfyAnalytics {
  static const String _captureUrl = 'https://eu.i.posthog.com/i/v0/e/';
  static const String _prefInstallId = 'analyticsInstallId';

  /// Property keys that must never reach analytics, whatever a call site passes. Mirrors the
  /// API-side sanitizer in clingfy-labs `analytics.service.ts`.
  static const Set<String> _forbiddenKeys = {
    'file_path',
    'path',
    'directory',
    'filename',
    'window_title',
    'title',
    'transcript',
    'prompt',
    'license_key',
    'email',
    'authorization',
    'access_token',
  };

  static http.Client? _client;
  static String _distinctId = '';
  static bool _enabled = false;
  static bool _debugDisabled = kDebugMode;
  static bool _internal = false;
  static bool _testMode = false;

  static bool get isActive =>
      _enabled &&
      // Test mode runs the real capture path even in debug so the founder can verify the
      // pipeline from `flutter run`; a normal debug run still emits nothing.
      (!_debugDisabled || _testMode) &&
      BuildConfig.posthogToken.isNotEmpty &&
      _distinctId.isNotEmpty;

  /// Idempotent startup init. [enabled] is the persisted user setting. [internal] marks THIS
  /// install so its events are excluded from real numbers (`is_internal`); [testMode] enters the
  /// manual test channel (`is_test`, and capture runs even in debug) — both mirror the web
  /// `?clingfy_internal` / `?clingfy_test` device flags. Test seams: [client], [debugOverride]
  /// (tests run in debug mode, which would otherwise hard-disable everything), and [prefs].
  static Future<void> init({
    required bool enabled,
    bool internal = false,
    bool testMode = false,
    http.Client? client,
    bool? debugOverride,
    SharedPreferences? prefs,
  }) async {
    _enabled = enabled;
    _internal = internal;
    _testMode = testMode;
    _debugDisabled = debugOverride ?? kDebugMode;
    _client ??= client ?? http.Client();
    if ((_debugDisabled && !_testMode) || BuildConfig.posthogToken.isEmpty) {
      return;
    }
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      var id = p.getString(_prefInstallId);
      if (id == null || id.isEmpty) {
        id = const Uuid().v4();
        await p.setString(_prefInstallId, id);
      }
      _distinctId = id;
    } catch (e) {
      // No install id -> stay disabled rather than fabricate unstable ids per launch.
      Log.w('Analytics', 'Install id unavailable; analytics disabled: $e');
      _distinctId = '';
    }
  }

  /// Runtime toggle — bound to the "Share anonymous usage analytics" setting.
  // ignore: avoid_positional_boolean_parameters — mirrors the settings-setter convention.
  static void setEnabled(bool value) {
    _enabled = value;
  }

  /// Runtime toggle — marks this install internal (its events carry `is_internal` and drop out of
  /// real numbers). Bound to the owner-only "Mark this device internal" setting.
  // ignore: avoid_positional_boolean_parameters — mirrors the settings-setter convention.
  static void setInternal(bool value) {
    _internal = value;
  }

  /// Runtime toggle — the manual test channel (`is_test`, which also implies internal). In a
  /// RELEASE build this takes effect immediately; from a DEBUG build capture is gated at init, so
  /// set `CLINGFY_ANALYTICS_TEST=1` (or the persisted setting) BEFORE launch to exercise the
  /// pipeline from source.
  // ignore: avoid_positional_boolean_parameters — mirrors the settings-setter convention.
  static void setTestMode(bool value) {
    _testMode = value;
  }

  /// Fire-and-forget capture. Never throws, never blocks the caller.
  static void capture(
    String event, {
    Map<String, Object?> properties = const {},
  }) {
    if (!isActive) return;
    final sanitized = <String, Object?>{
      for (final entry in properties.entries)
        if (!_forbiddenKeys.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    final payload = <String, Object?>{
      'api_key': BuildConfig.posthogToken,
      'event': event,
      'distinct_id': _distinctId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'properties': <String, Object?>{
        ...sanitized,
        'environment': BuildConfig.isProd() ? 'production' : 'development',
        'product': 'clingfy_desktop',
        'source': 'desktop_client',
        'platform': Platform.isWindows
            ? 'windows'
            : Platform.isMacOS
            ? 'macos'
            : Platform.operatingSystem,
        'app_version': BuildConfig.buildName.isEmpty
            ? 'unknown'
            : BuildConfig.buildName,
        'build_number': BuildConfig.buildNumber.isEmpty
            ? 'unknown'
            : BuildConfig.buildNumber,
        // Founder-device exclusion + manual test channel (mirrors the web `?clingfy_internal` /
        // `?clingfy_test` flags). Test implies internal, so a test event is always excluded from
        // real numbers too.
        if (_internal || _testMode) 'is_internal': true,
        if (_testMode) 'is_test': true,
        'analytics_schema_version': 1,
        // Desktop events are anonymous business telemetry — never mint a PostHog person.
        r'$process_person_profile': false,
      },
    };
    _client!
        .post(
          Uri.parse(_captureUrl),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 10))
        .then((response) {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            Log.w(
              'Analytics',
              'Capture rejected (${response.statusCode}) for $event',
            );
          }
        })
        .catchError((Object e) {
          // Offline / DNS / timeout: drop the event silently — never disturb the app.
          Log.d('Analytics', 'Capture dropped for $event: $e');
        });
  }

  /// Test-only: reset static state between tests.
  @visibleForTesting
  static void resetForTest() {
    _client = null;
    _distinctId = '';
    _enabled = false;
    _internal = false;
    _testMode = false;
    _debugDisabled = kDebugMode;
  }
}
