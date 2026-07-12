import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:flutter_test/flutter_test.dart';

LogEvent _logEvent({
  String origin = 'native',
  String level = 'ERROR',
  String category = 'Recording',
  Map<String, dynamic>? context,
}) {
  return LogEvent(
    ts: '2026-06-11T10:00:00.000',
    level: level,
    origin: origin,
    category: category,
    message: 'message',
    sessionId: 'session',
    context: context,
  );
}

void main() {
  test('capture diagnostics prefers capture destination free bytes', () {
    final diagnostics = CaptureDiagnostics.fromMap({
      'backend': 'sck',
      'captureFps': 60,
      'captureDestinationFreeBytes': 1234,
      'saveFolderFreeBytes': 5678,
      'recordingsFreeBytes': 91011,
    });

    expect(diagnostics.captureDestinationFreeBytes, 1234);
    expect(diagnostics.bestFreeBytes, 1234);
    expect(diagnostics.toMap()['captureDestinationFreeBytes'], 1234);
    expect(diagnostics.toMap()['bestFreeBytes'], 1234);
  });

  test('capture diagnostics falls back to save folder then recordings', () {
    const saveFolderPreferred = CaptureDiagnostics(
      saveFolderFreeBytes: 2048,
      recordingsFreeBytes: 1024,
    );
    const recordingsFallback = CaptureDiagnostics(recordingsFreeBytes: 4096);

    expect(saveFolderPreferred.bestFreeBytes, 2048);
    expect(recordingsFallback.bestFreeBytes, 4096);
  });

  group('native log Sentry fingerprint (Phase 10.4)', () {
    test('native ERROR with a context code groups by [native-log, category, '
        'code]', () {
      final fingerprint = ClingfyTelemetry.nativeLogFingerprint(
        _logEvent(context: {'code': 'ENCODER_VIDEO_ERROR'}),
      );

      expect(fingerprint, ['native-log', 'Recording', 'ENCODER_VIDEO_ERROR']);
    });

    test('non-error native logs keep default grouping', () {
      expect(
        ClingfyTelemetry.nativeLogFingerprint(
          _logEvent(level: 'WARNING', context: {'code': 'X'}),
        ),
        isNull,
      );
    });

    test('flutter-origin errors keep default grouping', () {
      expect(
        ClingfyTelemetry.nativeLogFingerprint(
          _logEvent(origin: 'flutter', context: {'code': 'X'}),
        ),
        isNull,
      );
    });

    test('missing, empty, or non-string codes keep default grouping', () {
      expect(ClingfyTelemetry.nativeLogFingerprint(_logEvent()), isNull);
      expect(
        ClingfyTelemetry.nativeLogFingerprint(_logEvent(context: {'code': ''})),
        isNull,
      );
      expect(
        ClingfyTelemetry.nativeLogFingerprint(
          _logEvent(context: {'code': 1234}),
        ),
        isNull,
      );
    });
  });
}
