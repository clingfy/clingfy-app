/// Phase 10.2: the rich Windows permission/device picture behind
/// `getWindowsPermissionDetails`.
///
/// Wire names come from the native converters in
/// `windows/runner/Permissions/camera_readiness.cpp`
/// (CameraReadinessCodeName / CameraPermissionName) — keep in sync.
/// The method is Windows-only; on macOS (or older Windows natives) the
/// bridge returns null and callers fall back to the flat boolean snapshot.
library;

/// Resolved "can the camera overlay work right now" verdict.
enum WindowsCameraReadiness {
  ready,
  permissionDeniedSystem,
  permissionDeniedUser,
  permissionNotDetermined,
  noDevicesAvailable,
  noDeviceSelected,
  selectedDeviceMissing,
  unknown;

  static WindowsCameraReadiness parse(String? raw) {
    for (final value in WindowsCameraReadiness.values) {
      if (value.name == raw) return value;
    }
    return WindowsCameraReadiness.unknown;
  }
}

/// AppCapabilityAccess privacy bucket (mic today; capability-agnostic).
enum WindowsCapabilityAccess {
  granted,
  deniedBySystem,
  deniedByUser,
  notDetermined,
  unavailableApi,
  unknown;

  static WindowsCapabilityAccess parse(String? raw) {
    for (final value in WindowsCapabilityAccess.values) {
      if (value.name == raw) return value;
    }
    return WindowsCapabilityAccess.unknown;
  }
}

class WindowsCameraDetails {
  const WindowsCameraDetails({
    required this.readiness,
    required this.reason,
    required this.deviceSelected,
    required this.devicesAvailable,
  });

  final WindowsCameraReadiness readiness;

  /// Native log-friendly explanation (English; for diagnostics, not UI).
  final String reason;
  final bool deviceSelected;
  final int devicesAvailable;
}

class WindowsMicrophoneDetails {
  const WindowsMicrophoneDetails({
    required this.access,
    required this.deviceSelected,
    required this.selectedDeviceMissing,
  });

  final WindowsCapabilityAccess access;

  /// False = the system default endpoint is in use (never "missing").
  final bool deviceSelected;
  final bool selectedDeviceMissing;
}

class WindowsPermissionDetails {
  const WindowsPermissionDetails({
    required this.camera,
    required this.microphone,
  });

  final WindowsCameraDetails camera;
  final WindowsMicrophoneDetails microphone;

  static WindowsPermissionDetails? fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return null;
    final cameraRaw = map['camera'];
    final micRaw = map['microphone'];
    final camera = cameraRaw is Map
        ? WindowsCameraDetails(
            readiness: WindowsCameraReadiness.parse(
              cameraRaw['code']?.toString(),
            ),
            reason: cameraRaw['reason']?.toString() ?? '',
            deviceSelected: cameraRaw['deviceSelected'] == true,
            devicesAvailable:
                (cameraRaw['devicesAvailable'] as num?)?.toInt() ?? 0,
          )
        : const WindowsCameraDetails(
            readiness: WindowsCameraReadiness.unknown,
            reason: '',
            deviceSelected: false,
            devicesAvailable: 0,
          );
    final microphone = micRaw is Map
        ? WindowsMicrophoneDetails(
            access: WindowsCapabilityAccess.parse(micRaw['access']?.toString()),
            deviceSelected: micRaw['deviceSelected'] == true,
            selectedDeviceMissing: micRaw['selectedDeviceMissing'] == true,
          )
        : const WindowsMicrophoneDetails(
            access: WindowsCapabilityAccess.unknown,
            deviceSelected: false,
            selectedDeviceMissing: false,
          );
    return WindowsPermissionDetails(camera: camera, microphone: microphone);
  }
}
