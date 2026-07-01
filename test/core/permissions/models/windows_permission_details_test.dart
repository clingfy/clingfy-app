import 'package:clingfy/core/permissions/models/windows_permission_details.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the full native reply shape', () {
    final details = WindowsPermissionDetails.fromMap({
      'camera': {
        'code': 'selectedDeviceMissing',
        'reason':
            'the selected camera is unavailable (disconnected or '
            'removed)',
        'deviceSelected': true,
        'devicesAvailable': 2,
      },
      'microphone': {
        'access': 'deniedBySystem',
        'deviceSelected': true,
        'selectedDeviceMissing': false,
      },
      'screenRecording': {'required': false},
    });

    expect(details, isNotNull);
    expect(
      details!.camera.readiness,
      WindowsCameraReadiness.selectedDeviceMissing,
    );
    expect(details.camera.deviceSelected, isTrue);
    expect(details.camera.devicesAvailable, 2);
    expect(details.camera.reason, contains('unavailable'));
    expect(details.microphone.access, WindowsCapabilityAccess.deniedBySystem);
    expect(details.microphone.deviceSelected, isTrue);
    expect(details.microphone.selectedDeviceMissing, isFalse);
  });

  test('every native wire name round-trips', () {
    // Pinned against CameraReadinessCodeName / CameraPermissionName in
    // windows/runner/Permissions/camera_readiness.cpp.
    const readinessNames = [
      'ready',
      'permissionDeniedSystem',
      'permissionDeniedUser',
      'permissionNotDetermined',
      'noDevicesAvailable',
      'noDeviceSelected',
      'selectedDeviceMissing',
    ];
    for (final name in readinessNames) {
      expect(
        WindowsCameraReadiness.parse(name),
        isNot(WindowsCameraReadiness.unknown),
        reason: name,
      );
    }
    const accessNames = [
      'granted',
      'deniedBySystem',
      'deniedByUser',
      'notDetermined',
      'unavailableApi',
    ];
    for (final name in accessNames) {
      expect(
        WindowsCapabilityAccess.parse(name),
        isNot(WindowsCapabilityAccess.unknown),
        reason: name,
      );
    }
  });

  test('unknown codes and missing submaps degrade, never throw', () {
    expect(WindowsPermissionDetails.fromMap(null), isNull);

    final sparse = WindowsPermissionDetails.fromMap({'unrelated': 1});
    expect(sparse, isNotNull);
    expect(sparse!.camera.readiness, WindowsCameraReadiness.unknown);
    expect(sparse.microphone.access, WindowsCapabilityAccess.unknown);

    final future = WindowsPermissionDetails.fromMap({
      'camera': {'code': 'someFutureCode'},
      'microphone': {'access': 'someFutureBucket'},
    });
    expect(future!.camera.readiness, WindowsCameraReadiness.unknown);
    expect(future.microphone.access, WindowsCapabilityAccess.unknown);
  });
}
