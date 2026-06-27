import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logLevelFromName', () {
    test('parses names, aliases, and the UPPERCASE native forms', () {
      expect(logLevelFromName('debug'), LogLevel.debug);
      expect(logLevelFromName('DEBUG'), LogLevel.debug);
      expect(logLevelFromName('  Verbose  '), LogLevel.debug);
      expect(logLevelFromName('info'), LogLevel.info);
      expect(logLevelFromName('INFO'), LogLevel.info);
      expect(logLevelFromName('warning'), LogLevel.warning);
      expect(logLevelFromName('warn'), LogLevel.warning);
      expect(logLevelFromName('error'), LogLevel.error);
    });

    test('returns null for unknown/empty/null', () {
      expect(logLevelFromName('nope'), isNull);
      expect(logLevelFromName(''), isNull);
      expect(logLevelFromName(null), isNull);
    });
  });

  group('resolveLevel precedence', () {
    test('env override wins over the build default', () {
      expect(
        Log.resolveLevel(envValue: 'warning', buildDefaultIsVerbose: true),
        LogLevel.warning,
      );
      expect(
        Log.resolveLevel(envValue: 'error', buildDefaultIsVerbose: false),
        LogLevel.error,
      );
    });

    test('without an env override, falls back to the build default', () {
      // Verbose build (debug) → debug; non-verbose build (release/profile) →
      // info. This pins the release default that a debug test run can't observe
      // through the live kReleaseMode getter.
      expect(
        Log.resolveLevel(envValue: null, buildDefaultIsVerbose: true),
        LogLevel.debug,
      );
      expect(
        Log.resolveLevel(envValue: null, buildDefaultIsVerbose: false),
        LogLevel.info,
      );
    });

    test('an unparseable env value falls back to the build default', () {
      expect(
        Log.resolveLevel(envValue: 'bogus', buildDefaultIsVerbose: false),
        LogLevel.info,
      );
    });
  });

  group('Log threshold', () {
    test('setMinLevel updates the threshold', () {
      Log.setMinLevel(LogLevel.warning);
      expect(Log.minLevel, LogLevel.warning);
      Log.setMinLevel(LogLevel.debug);
      expect(Log.minLevel, LogLevel.debug);
    });

    test('setVerbose(true) forces debug and returns it', () {
      Log.setMinLevel(LogLevel.error);
      final level = Log.setVerbose(true);
      expect(level, LogLevel.debug);
      expect(Log.minLevel, LogLevel.debug);
    });

    test('setVerbose(false) resolves the env/build default', () {
      // Tests run as a debug build with no env override, so the default is
      // debug; the point is that it returns whatever it set the level to.
      final level = Log.setVerbose(false);
      expect(level, Log.minLevel);
      expect(level, LogLevel.debug);
    });
  });
}
