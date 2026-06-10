import 'package:flutter/foundation.dart';
import 'package:clingfy/app/permissions/permissions_onboarding_store.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/storage_snapshot.dart';
import 'package:clingfy/core/permissions/models/permission_status_snapshot.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/core/permissions/models/windows_permission_details.dart';
import 'package:clingfy/core/permissions/recording_start_preflight_rules.dart'
    as permissions_rules;
import 'package:clingfy/ui/platform/platform_kind.dart';

class PermissionsController extends ChangeNotifier {
  PermissionsController({required NativeBridge bridge})
    : _bridge = bridge,
      _onboardingStore = PermissionsOnboardingStore();

  final NativeBridge _bridge;
  final PermissionsOnboardingStore _onboardingStore;

  bool loading = true;

  PermissionStatusSnapshot _status = const PermissionStatusSnapshot();

  /// Phase 10.2 (Windows-only): the rich readiness picture behind the
  /// boolean snapshot — camera readiness code, detailed mic privacy
  /// bucket, selected-device-missing flags. Null on macOS and whenever
  /// the native call fails; UIs must always have a boolean fallback.
  WindowsPermissionDetails? _windowsDetails;
  WindowsPermissionDetails? get windowsDetails => _windowsDetails;

  bool get screenRecording => _status.screenRecording;
  set screenRecording(bool v) {
    _status = _status.copyWith(screenRecording: v);
    notifyListeners();
  }

  bool get microphone => _status.microphone;
  set microphone(bool v) {
    _status = _status.copyWith(microphone: v);
    notifyListeners();
  }

  bool get camera => _status.camera;
  set camera(bool v) {
    _status = _status.copyWith(camera: v);
    notifyListeners();
  }

  bool get accessibility => _status.accessibility;
  set accessibility(bool v) {
    _status = _status.copyWith(accessibility: v);
    notifyListeners();
  }

  Future<bool> getOnboardingSeen() async {
    return _onboardingStore.getSeen();
  }

  Future<void> setOnboardingSeen(bool v) async {
    await _onboardingStore.setSeen(v);
  }

  Future<int> getOnboardingStep() async {
    return _onboardingStore.getStep();
  }

  Future<void> setOnboardingStep(int step) async {
    await _onboardingStore.setStep(step);
  }

  Future<void> resetOnboardingStep() async {
    await _onboardingStore.resetStep();
  }

  int _refreshSeq = 0;

  Future<void> refresh() async {
    final seq = ++_refreshSeq;

    loading = true;
    notifyListeners();

    try {
      final m = await _bridge.getPermissionStatus();
      // Windows-only enrichment; getWindowsPermissionDetails never throws
      // (null on macOS / legacy native / failure).
      final details = isWindows()
          ? await _bridge.getWindowsPermissionDetails()
          : null;

      // If another refresh started after this one, ignore this result
      if (seq != _refreshSeq) return;

      _status = PermissionStatusSnapshot.fromStatusMap(m);
      _windowsDetails = details;
    } catch (_) {
    } finally {
      if (seq == _refreshSeq) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> requestScreen() async {
    await _bridge.requestScreenRecordingPermission();
    await refresh();
  }

  Future<void> requestMic() async {
    await _bridge.requestMicrophonePermission();
    await refresh();
  }

  Future<void> requestCam() async {
    await _bridge.requestCameraPermission();
    await refresh();
  }

  Future<void> openAccessibility() async {
    await _bridge.openAccessibilitySettings();
  }

  Future<void> openMicrophoneSettings() async {
    await _bridge.openSystemSettings('microphone');
  }

  Future<void> openCameraSettings() async {
    await _bridge.openSystemSettings('camera');
  }

  /// Phase 10.2 (Windows): ms-settings:sound — input/output device page,
  /// the actionable target for "selected mic missing" / system-audio states.
  Future<void> openSoundSettings() async {
    await _bridge.openSystemSettings('sound');
  }

  Future<void> openScreenSettings() async {
    await _bridge.openScreenRecordingSettings();
  }

  Future<void> relaunch() async {
    await _bridge.relaunchApp();
  }

  RecordingStartPreflight buildRecordingStartPreflight({
    required RecordingStartIntent intent,
    StorageSnapshot? storageSnapshot,
  }) {
    return permissions_rules.buildRecordingStartPreflight(
      status: _status,
      intent: intent,
      storageSnapshot: storageSnapshot,
    );
  }

  Future<RecordingStartPreflight> prepareRecordingStartPreflight({
    required RecordingStartIntent intent,
  }) async {
    await refresh();
    StorageSnapshot? storageSnapshot;
    try {
      storageSnapshot = await _bridge.getStorageSnapshot();
    } catch (_) {}
    return buildRecordingStartPreflight(
      intent: intent,
      storageSnapshot: storageSnapshot,
    );
  }

  bool get requiredOk => true;
}
