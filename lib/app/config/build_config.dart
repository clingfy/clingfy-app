import 'package:flutter/foundation.dart' show kDebugMode;

// lib/config/build_config.dart

class BuildConfig {
  static const String _rawTimestamp = String.fromEnvironment(
    'BUILD_TIMESTAMP',
    defaultValue: '',
  );

  static DateTime get buildDate {
    if (_rawTimestamp.isEmpty) {
      // Fallback for local runs without build-time defines.
      return DateTime.now();
    }
    return DateTime.parse(_rawTimestamp);
  }

  static const String commitHash = String.fromEnvironment(
    'COMMIT_HASH',
    defaultValue: 'unknown',
  );

  static const String buildId = String.fromEnvironment(
    'BUILD_ID',
    defaultValue: 'local',
  );

  static const String branch = String.fromEnvironment(
    'BUILD_BRANCH',
    defaultValue: 'local',
  );

  static const String sentryDsn = String.fromEnvironment(
    'SENTRY_DSN',
    defaultValue: '',
  );
  static const String sentryEnvironmentDefine = String.fromEnvironment(
    'SENTRY_ENVIRONMENT',
    defaultValue: '',
  );
  static const String sentryTracesSampleRateDefine = String.fromEnvironment(
    'SENTRY_TRACES_SAMPLE_RATE',
    defaultValue: '',
  );

  static const String buildName = String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: '',
  );
  static const String buildNumber = String.fromEnvironment(
    'FLUTTER_BUILD_NUMBER',
    defaultValue: '',
  );

  static const String apiBaseURL = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
  static const String siteURL = String.fromEnvironment(
    'CLINGFY_SITE_URL',
    defaultValue: 'https://clingfy.com',
  );

  static const String appEnv = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'dev',
  );

  static bool isProd() => appEnv.toLowerCase() == "prod";

  static bool isDev() => !isProd();

  static bool showDevPreviewResolutionControl({
    String? appEnvOverride,
    String? buildIdOverride,
    bool? isDebugOverride,
  }) {
    final resolvedEnv = (appEnvOverride ?? appEnv).toLowerCase();
    final resolvedBuildId = (buildIdOverride ?? buildId).toLowerCase();
    final resolvedIsDebug = isDebugOverride ?? kDebugMode;
    return resolvedEnv == 'dev' &&
        resolvedBuildId == 'local' &&
        resolvedIsDebug;
  }
}
