import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
