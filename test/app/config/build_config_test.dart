import 'package:clingfy/app/config/build_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BuildConfig.showDevPreviewResolutionControl', () {
    test('returns true for hosted dev builds', () {
      expect(
        BuildConfig.showDevPreviewResolutionControl(
          appEnvOverride: 'dev',
          buildIdOverride: '123',
          isDebugOverride: true,
        ),
        isTrue,
      );
    });

    test('returns false for prod builds', () {
      expect(
        BuildConfig.showDevPreviewResolutionControl(
          appEnvOverride: 'prod',
          buildIdOverride: '123',
          isDebugOverride: true,
        ),
        isFalse,
      );
    });

    test('returns false for local build id', () {
      expect(
        BuildConfig.showDevPreviewResolutionControl(
          appEnvOverride: 'dev',
          buildIdOverride: 'local',
          isDebugOverride: true,
        ),
        isFalse,
      );
    });

    test('returns false for local app env', () {
      expect(
        BuildConfig.showDevPreviewResolutionControl(
          appEnvOverride: 'local',
          buildIdOverride: '123',
          isDebugOverride: true,
        ),
        isFalse,
      );
    });

    test('returns false for non-debug builds', () {
      expect(
        BuildConfig.showDevPreviewResolutionControl(
          appEnvOverride: 'dev',
          buildIdOverride: '123',
          isDebugOverride: false,
        ),
        isFalse,
      );
    });
  });
}
