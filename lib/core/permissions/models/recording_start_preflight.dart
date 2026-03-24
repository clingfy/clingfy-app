import 'package:clingfy/core/models/storage_snapshot.dart';

enum MissingPermissionKind {
  screenRecording,
  microphone,
  camera,
  accessibility,
}

enum RecordingStoragePreflightStatus { clear, warning, critical }

class RecordingStoragePreflight {
  const RecordingStoragePreflight({
    required this.status,
    required this.availableBytes,
    required this.warningThresholdBytes,
    required this.criticalThresholdBytes,
  });

  factory RecordingStoragePreflight.fromSnapshot(StorageSnapshot snapshot) {
    final status = switch (snapshot.status) {
      StorageHealthStatus.healthy => RecordingStoragePreflightStatus.clear,
      StorageHealthStatus.warning => RecordingStoragePreflightStatus.warning,
      StorageHealthStatus.critical => RecordingStoragePreflightStatus.critical,
    };
    return RecordingStoragePreflight(
      status: status,
      availableBytes: snapshot.systemAvailableBytes,
      warningThresholdBytes: snapshot.warningThresholdBytes,
      criticalThresholdBytes: snapshot.criticalThresholdBytes,
    );
  }

  final RecordingStoragePreflightStatus status;
  final int availableBytes;
  final int warningThresholdBytes;
  final int criticalThresholdBytes;

  bool get needsAttention => status != RecordingStoragePreflightStatus.clear;
  bool get isBlocking => status == RecordingStoragePreflightStatus.critical;
  bool get isWarning => status == RecordingStoragePreflightStatus.warning;
}

class RecordingStartIntent {
  const RecordingStartIntent({
    required this.needsScreenRecording,
    required this.needsMicrophone,
    required this.needsCamera,
    required this.needsAccessibility,
  });

  final bool needsScreenRecording;
  final bool needsMicrophone;
  final bool needsCamera;
  final bool needsAccessibility;
}

class RecordingStartPreflight {
  const RecordingStartPreflight({
    required this.intent,
    required this.missingHard,
    required this.missingOptional,
    this.storage,
  });

  final RecordingStartIntent intent;
  final List<MissingPermissionKind> missingHard;
  final List<MissingPermissionKind> missingOptional;
  final RecordingStoragePreflight? storage;

  bool get isClear =>
      missingHard.isEmpty &&
      missingOptional.isEmpty &&
      !(storage?.needsAttention ?? false);
  bool get hasHardBlocker => missingHard.isNotEmpty;
  bool get hasOptionalGaps => missingOptional.isNotEmpty;
  bool get hasPermissionAttention => hasHardBlocker || hasOptionalGaps;
  bool get hasStorageAttention => storage?.needsAttention ?? false;
}

class RecordingStartOverrides {
  const RecordingStartOverrides({
    this.disableMicrophone = false,
    this.disableCameraOverlay = false,
    this.disableCursorHighlight = false,
    this.allowLowStorageBypass = false,
  });

  final bool disableMicrophone;
  final bool disableCameraOverlay;
  final bool disableCursorHighlight;
  final bool allowLowStorageBypass;
}
