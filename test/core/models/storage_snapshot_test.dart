import 'package:clingfy/core/models/storage_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromMap populates fields and derived totals', () {
    final snapshot = StorageSnapshot.fromMap({
      'systemTotalBytes': 500 * 1024 * 1024 * 1024,
      'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
      'recordingsBytes': 4 * 1024 * 1024,
      'tempBytes': 2 * 1024 * 1024,
      'logsBytes': 512 * 1024,
      'recordingsPath': '/tmp/recordings',
      'tempPath': '/tmp/temp',
      'logsPath': '/tmp/logs',
      'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
      'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
    });

    expect(snapshot.systemUsedBytes, 300 * 1024 * 1024 * 1024);
    expect(snapshot.clingfyTotalBytes, 6815744);
    expect(snapshot.status, StorageHealthStatus.healthy);
  });

  test('status reflects warning and critical thresholds', () {
    const warningSnapshot = StorageSnapshot(
      systemTotalBytes: 500 * 1024 * 1024 * 1024,
      systemAvailableBytes: 15 * 1024 * 1024 * 1024,
      recordingsBytes: 0,
      tempBytes: 0,
      logsBytes: 0,
      recordingsPath: '/tmp/recordings',
      tempPath: '/tmp/temp',
      logsPath: '/tmp/logs',
      warningThresholdBytes: 20 * 1024 * 1024 * 1024,
      criticalThresholdBytes: 10 * 1024 * 1024 * 1024,
    );
    const criticalSnapshot = StorageSnapshot(
      systemTotalBytes: 500 * 1024 * 1024 * 1024,
      systemAvailableBytes: 5 * 1024 * 1024 * 1024,
      recordingsBytes: 0,
      tempBytes: 0,
      logsBytes: 0,
      recordingsPath: '/tmp/recordings',
      tempPath: '/tmp/temp',
      logsPath: '/tmp/logs',
      warningThresholdBytes: 20 * 1024 * 1024 * 1024,
      criticalThresholdBytes: 10 * 1024 * 1024 * 1024,
    );

    expect(warningSnapshot.isWarning, isTrue);
    expect(criticalSnapshot.isCritical, isTrue);
  });
}
