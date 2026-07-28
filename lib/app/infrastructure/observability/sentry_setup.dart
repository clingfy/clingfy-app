import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/app/infrastructure/observability/crash_reporting_consent.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class SentrySetup {
  static Future<void> run({
    required Future<void> Function({RemoteLogSink? remoteLogSink}) appRunner,
  }) async {
    if (BuildConfig.sentryDsn.isEmpty) {
      await appRunner();
      return;
    }

    // Read the user's choice BEFORE init. Sentry starts before any controller
    // exists, so this is the only point where it can be honoured.
    await CrashReportingConsent.load();

    // Opted out: do not initialise at all. `beforeSend` would drop Dart events
    // but NOT native crashes — `enableNativeCrashHandling` installs an
    // out-of-process handler that never reaches Dart. Skipping init is the
    // only way "off" actually means off.
    if (!CrashReportingConsent.enabled) {
      Log.i('Telemetry', 'Crash reporting is off — Sentry not initialised');
      await appRunner();
      return;
    }

    await SentryFlutter.init(
      (options) {
        options.dsn = BuildConfig.sentryDsn;
        // Honours a mid-session opt-out for everything raised in Dart. The
        // native handler stays until the next launch, which is what the
        // settings copy tells the user.
        options.beforeSend = (event, hint) async =>
            CrashReportingConsent.enabled ? event : null;
        options.environment = _resolveSentryEnvironment();
        options.release = _resolveSentryRelease();
        options.attachStacktrace = true;
        options.enableNativeCrashHandling = true;
        options.maxBreadcrumbs = 200;
        options.sendDefaultPii = false;
        options.tracesSampleRate = _resolveSampleRate(
          BuildConfig.sentryTracesSampleRateDefine,
          fallback: 0.0,
        );
      },
      appRunner: () async {
        await appRunner(remoteLogSink: ClingfyTelemetry.logSink);
      },
    );
  }

  static double _resolveSampleRate(
    String rawValue, {
    required double fallback,
  }) {
    if (rawValue.isEmpty) return fallback;
    final parsed = double.tryParse(rawValue);
    if (parsed == null || parsed < 0 || parsed > 1) return fallback;
    return parsed;
  }

  static String _resolveSentryEnvironment() {
    if (BuildConfig.sentryEnvironmentDefine.isNotEmpty) {
      return BuildConfig.sentryEnvironmentDefine;
    }
    return kReleaseMode ? 'production' : 'development';
  }

  static String _resolveSentryRelease() {
    final release = buildSentryRelease(
      buildName: BuildConfig.buildName,
      buildNumber: BuildConfig.buildNumber,
      commitHash: BuildConfig.commitHash,
    );

    // Loud, because the failure is otherwise invisible from inside the app.
    // Windows shipped for months tagging every build `clingfy@++<commit>` --
    // the release lane never passed FLUTTER_BUILD_NAME/NUMBER as dart-defines,
    // so both were '' and no crash report could be mapped to a build. Nothing
    // detected it; it was found by reading Sentry's release list by hand.
    if (!isReleaseTagComplete(
      buildName: BuildConfig.buildName,
      buildNumber: BuildConfig.buildNumber,
    )) {
      Log.e(
        'Telemetry',
        'Sentry release tag is missing the version and/or build number — '
            'crash reports cannot be mapped to a build. The build did not pass '
            'FLUTTER_BUILD_NAME / FLUTTER_BUILD_NUMBER as dart-defines.',
        null,
        null,
        {'release': release},
      );
    }
    return release;
  }

  /// The Sentry release string: `clingfy@<version>+<build>+<commit>`.
  ///
  /// One shared format across macOS and Windows — both platforms feed it the
  /// same three dart-defines, so a report from either maps back to an exact
  /// build. The commit is dropped when unavailable (a local build with no
  /// `COMMIT_HASH`), which is a real, tolerable case; a missing version or
  /// build number is NOT — see [isReleaseTagComplete].
  @visibleForTesting
  static String buildSentryRelease({
    required String buildName,
    required String buildNumber,
    required String commitHash,
  }) {
    final base = 'clingfy@$buildName+$buildNumber';
    // 'unknown' is what the build scripts emit when `git rev-parse` fails; it
    // is not a commit and must not be pinned to one in Sentry.
    if (commitHash.isEmpty || commitHash == 'unknown') return base;
    return '$base+$commitHash';
  }

  /// Whether the release tag identifies an actual build.
  ///
  /// False means the tag degraded to something like `clingfy@++abc1234` or
  /// `clingfy@+`, which Sentry accepts happily and which is useless: it groups
  /// every build of that shape under one release.
  @visibleForTesting
  static bool isReleaseTagComplete({
    required String buildName,
    required String buildNumber,
  }) {
    return buildName.trim().isNotEmpty && buildNumber.trim().isNotEmpty;
  }
}
