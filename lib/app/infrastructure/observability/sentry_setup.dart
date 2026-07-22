import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/core/logging/logger_service.dart';
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

    await SentryFlutter.init(
      (options) {
        options.dsn = BuildConfig.sentryDsn;
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
    final commitHash = BuildConfig.commitHash;
    if (commitHash.isNotEmpty && commitHash != 'unknown') {
      return 'clingfy@${BuildConfig.buildName}+${BuildConfig.buildNumber}+$commitHash';
    }
    return 'clingfy@${BuildConfig.buildName}+${BuildConfig.buildNumber}';
  }
}
