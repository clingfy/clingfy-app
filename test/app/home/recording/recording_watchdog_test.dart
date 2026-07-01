import 'dart:async';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
// fake_async ships with the Flutter SDK as a flutter_test dependency; the
// project deliberately doesn't redeclare it (pubspec is outside the Dart
// workstream's ownership in Phase 10.4).
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Phase 10.4: the per-phase watchdogs that recover the Windows UI when a
/// native workflow event never arrives. Before these, the verified gap was
/// that NOTHING recovered the busy phases — a dropped event left the app
/// stuck forever.
///
/// Fire paths use fakeAsync: timers armed by controller methods invoked
/// inside the FakeAsync zone are fake and can be elapsed. Workflow EVENTS
/// cannot be delivered inside fakeAsync (the NativeBridge broadcast stream
/// pipeline schedules on the root zone), so event-driven setup happens with
/// real async before entering fakeAsync, and cancel-path tests use small
/// real durations via [RecordingController.debugWatchdogDurations].
Future<void> _emitWorkflowEvent(Map<String, Object?> event) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.workflowEvents,
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) => completer.complete(),
  );
  await completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
    debugPlatformKindOverride = PlatformKind.windows;
  });

  tearDown(() async {
    debugPlatformKindOverride = null;
    RecordingController.debugWatchdogDurations = null;
    await clearCommonNativeMocks();
  });

  Future<({RecordingController recording, SettingsController settings})>
  createHarness() async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    addTearDown(recording.dispose);
    addTearDown(settings.dispose);
    return (recording: recording, settings: settings);
  }

  test('startingRecording watchdog fires after 30s and idles with '
      'RECORDING_START_TIMEOUT', () async {
    final harness = await createHarness();

    fakeAsync((async) {
      harness.recording.beginRecordingStartIntent();
      expect(harness.recording.phase, WorkflowPhase.startingRecording);

      async.elapse(const Duration(seconds: 29));
      expect(harness.recording.phase, WorkflowPhase.startingRecording);
      expect(harness.recording.errorCode, isNull);

      async.elapse(const Duration(seconds: 1));
      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(
        harness.recording.errorCode,
        DartSynthesizedErrorCode.recordingStartTimeout,
      );
      async.flushMicrotasks();
    });
  });

  test(
    'startingRecording watchdog is canceled when recordingStarted arrives',
    () async {
      RecordingController.debugWatchdogDurations = {
        WorkflowPhase.startingRecording: const Duration(milliseconds: 200),
      };
      final harness = await createHarness();

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });
      expect(harness.recording.phase, WorkflowPhase.recording);

      // Far past the 200ms watchdog: a leaked timer would have idled the
      // controller with RECORDING_START_TIMEOUT by now.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(harness.recording.phase, WorkflowPhase.recording);
      expect(harness.recording.errorCode, isNull);
    },
  );

  test('finalizingRecording watchdog fires after 120s and idles with '
      'RECORDING_FINALIZE_TIMEOUT', () async {
    final harness = await createHarness();

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });

    fakeAsync((async) {
      unawaited(harness.recording.stopRecording());
      async.flushMicrotasks();
      expect(harness.recording.phase, WorkflowPhase.finalizingRecording);

      async.elapse(const Duration(seconds: 119));
      expect(harness.recording.phase, WorkflowPhase.finalizingRecording);

      async.elapse(const Duration(seconds: 1));
      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(
        harness.recording.errorCode,
        DartSynthesizedErrorCode.recordingFinalizeTimeout,
      );
      async.flushMicrotasks();
    });
  });

  test('finalizingRecording watchdog is canceled when recordingFinalized '
      'arrives', () async {
    RecordingController.debugWatchdogDurations = {
      WorkflowPhase.finalizingRecording: const Duration(milliseconds: 200),
    };
    final harness = await createHarness();

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    await harness.recording.stopRecording();
    expect(harness.recording.phase, WorkflowPhase.finalizingRecording);

    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/test.clingfyproj',
    });
    expect(harness.recording.phase, WorkflowPhase.openingPreview);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    // No spurious finalize timeout after the real event won the race.
    expect(harness.recording.phase, WorkflowPhase.openingPreview);
    expect(harness.recording.errorCode, isNull);
  });

  test('openingPreview watchdog fires after 30s, sets PREVIEW_TIMEOUT, closes '
      'the preview, and the closingPreview watchdog backstops to idle keeping '
      'the error', () async {
    final harness = await createHarness();

    fakeAsync((async) {
      harness.recording.openExistingProject('/tmp/stuck.clingfyproj');
      expect(harness.recording.phase, WorkflowPhase.openingPreview);

      async.elapse(const Duration(seconds: 30));
      // previewFailed-equivalent: error set, native close requested.
      expect(harness.recording.phase, WorkflowPhase.closingPreview);
      expect(
        harness.recording.errorCode,
        DartSynthesizedErrorCode.previewTimeout,
      );

      // previewClosed never arrives either — the closingPreview watchdog
      // is the backstop and must KEEP the error.
      async.elapse(const Duration(seconds: 15));
      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(
        harness.recording.errorCode,
        DartSynthesizedErrorCode.previewTimeout,
      );
      async.flushMicrotasks();
    });
  });

  test('previewLoading watchdog fires after 30s and is treated like a preview '
      'failure with PREVIEW_TIMEOUT', () async {
    final harness = await createHarness();

    fakeAsync((async) {
      harness.recording.openExistingProject('/tmp/stuck.clingfyproj');
      unawaited(harness.recording.handlePreviewHostMounted());
      async.flushMicrotasks();
      expect(harness.recording.phase, WorkflowPhase.previewLoading);

      async.elapse(const Duration(seconds: 30));
      expect(harness.recording.phase, WorkflowPhase.closingPreview);
      expect(
        harness.recording.errorCode,
        DartSynthesizedErrorCode.previewTimeout,
      );
      async.flushMicrotasks();
    });
  });

  test(
    'previewLoading watchdog is canceled when previewReady arrives',
    () async {
      RecordingController.debugWatchdogDurations = {
        WorkflowPhase.openingPreview: const Duration(milliseconds: 200),
        WorkflowPhase.previewLoading: const Duration(milliseconds: 200),
      };
      final harness = await createHarness();

      harness.recording.openExistingProject('/tmp/ok.clingfyproj');
      final sessionId = harness.recording.sessionId!;
      await harness.recording.handlePreviewHostMounted();
      await _emitWorkflowEvent({
        'type': 'previewReady',
        'sessionId': sessionId,
        'path': '/tmp/ok.clingfyproj',
        'token': 'tok',
      });
      expect(harness.recording.phase, WorkflowPhase.previewReady);

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(harness.recording.phase, WorkflowPhase.previewReady);
      expect(harness.recording.errorCode, isNull);
    },
  );

  test('closingPreview watchdog fires after 15s and idles', () async {
    final harness = await createHarness();

    harness.recording.openExistingProject('/tmp/ok.clingfyproj');
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'previewReady',
      'sessionId': sessionId,
      'path': '/tmp/ok.clingfyproj',
      'token': 'tok',
    });
    expect(harness.recording.phase, WorkflowPhase.previewReady);

    fakeAsync((async) {
      unawaited(harness.recording.closePreview());
      async.flushMicrotasks();
      expect(harness.recording.phase, WorkflowPhase.closingPreview);

      async.elapse(const Duration(seconds: 15));
      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(harness.recording.errorCode, isNull);
      async.flushMicrotasks();
    });
  });

  test('leaving startingRecording via cancel disarms the watchdog (no late '
      'spurious error)', () async {
    final harness = await createHarness();

    fakeAsync((async) {
      harness.recording.beginRecordingStartIntent();
      harness.recording.cancelPendingStartIntent();
      expect(harness.recording.phase, WorkflowPhase.idle);

      async.elapse(const Duration(seconds: 31));
      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(harness.recording.errorCode, isNull);
      async.flushMicrotasks();
    });
  });

  test('macOS arms no watchdogs — behavior unchanged', () async {
    debugPlatformKindOverride = PlatformKind.macos;
    final harness = await createHarness();

    fakeAsync((async) {
      harness.recording.beginRecordingStartIntent();
      async.elapse(const Duration(seconds: 31));
      // Still waiting on native, exactly like before Phase 10.4.
      expect(harness.recording.phase, WorkflowPhase.startingRecording);
      expect(harness.recording.errorCode, isNull);
      async.flushMicrotasks();
    });
  });
}
