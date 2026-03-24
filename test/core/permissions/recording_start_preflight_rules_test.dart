import 'package:clingfy/core/models/storage_snapshot.dart';
import 'package:clingfy/core/permissions/models/permission_status_snapshot.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/core/permissions/recording_start_preflight_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preflight is clear when all requested permissions are granted', () {
    final preflight = buildRecordingStartPreflight(
      status: const PermissionStatusSnapshot(
        screenRecording: true,
        microphone: true,
        camera: true,
        accessibility: true,
      ),
      intent: const RecordingStartIntent(
        needsScreenRecording: true,
        needsMicrophone: true,
        needsCamera: true,
        needsAccessibility: true,
      ),
    );

    expect(preflight.isClear, isTrue);
    expect(preflight.missingHard, isEmpty);
    expect(preflight.missingOptional, isEmpty);
  });

  test('screen recording missing is classified as hard blocker', () {
    final preflight = buildRecordingStartPreflight(
      status: const PermissionStatusSnapshot(
        screenRecording: false,
        microphone: true,
        camera: true,
        accessibility: true,
      ),
      intent: const RecordingStartIntent(
        needsScreenRecording: true,
        needsMicrophone: false,
        needsCamera: false,
        needsAccessibility: false,
      ),
    );

    expect(preflight.hasHardBlocker, isTrue);
    expect(
      preflight.missingHard,
      equals([MissingPermissionKind.screenRecording]),
    );
    expect(preflight.missingOptional, isEmpty);
  });

  test(
    'camera, microphone, and accessibility are optional gaps only when requested',
    () {
      final preflight = buildRecordingStartPreflight(
        status: const PermissionStatusSnapshot(
          screenRecording: true,
          microphone: false,
          camera: false,
          accessibility: false,
        ),
        intent: const RecordingStartIntent(
          needsScreenRecording: true,
          needsMicrophone: true,
          needsCamera: true,
          needsAccessibility: false,
        ),
      );

      expect(preflight.hasHardBlocker, isFalse);
      expect(
        preflight.missingOptional,
        equals([
          MissingPermissionKind.microphone,
          MissingPermissionKind.camera,
        ]),
      );
    },
  );

  test(
    'storage warning is attached when free space is below warning threshold',
    () {
      final preflight = buildRecordingStartPreflight(
        status: const PermissionStatusSnapshot(
          screenRecording: true,
          microphone: true,
          camera: true,
          accessibility: true,
        ),
        intent: const RecordingStartIntent(
          needsScreenRecording: true,
          needsMicrophone: false,
          needsCamera: false,
          needsAccessibility: false,
        ),
        storageSnapshot: const StorageSnapshot(
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
        ),
      );

      expect(preflight.hasPermissionAttention, isFalse);
      expect(preflight.hasStorageAttention, isTrue);
      expect(preflight.storage?.isWarning, isTrue);
    },
  );

  test('storage critical blocks clear preflight', () {
    final preflight = buildRecordingStartPreflight(
      status: const PermissionStatusSnapshot(
        screenRecording: true,
        microphone: true,
        camera: true,
        accessibility: true,
      ),
      intent: const RecordingStartIntent(
        needsScreenRecording: true,
        needsMicrophone: false,
        needsCamera: false,
        needsAccessibility: false,
      ),
      storageSnapshot: const StorageSnapshot(
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
      ),
    );

    expect(preflight.isClear, isFalse);
    expect(preflight.storage?.isBlocking, isTrue);
  });
}
