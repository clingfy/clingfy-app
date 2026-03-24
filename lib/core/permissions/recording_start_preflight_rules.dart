import 'package:clingfy/core/models/storage_snapshot.dart';
import 'package:clingfy/core/permissions/models/permission_status_snapshot.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';

RecordingStartPreflight buildRecordingStartPreflight({
  required PermissionStatusSnapshot status,
  required RecordingStartIntent intent,
  StorageSnapshot? storageSnapshot,
}) {
  final missingHard = <MissingPermissionKind>[];
  final missingOptional = <MissingPermissionKind>[];

  if (!status.screenRecording) {
    missingHard.add(MissingPermissionKind.screenRecording);
  }

  if (intent.needsMicrophone && !status.microphone) {
    missingOptional.add(MissingPermissionKind.microphone);
  }

  if (intent.needsCamera && !status.camera) {
    missingOptional.add(MissingPermissionKind.camera);
  }

  if (intent.needsAccessibility && !status.accessibility) {
    missingOptional.add(MissingPermissionKind.accessibility);
  }

  return RecordingStartPreflight(
    intent: intent,
    missingHard: missingHard,
    missingOptional: missingOptional,
    storage: storageSnapshot == null
        ? null
        : RecordingStoragePreflight.fromSnapshot(storageSnapshot),
  );
}
