import 'dart:async';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Phase 10.4: hardening of the recordingFailed / recordingFinalized event
/// paths — late/duplicate native failure events can no longer tear down a
/// finalized recording, and malformed finalized payloads keep their
/// synthetic RECORDING_FINALIZE_ERROR behavior.
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

Future<void> _emitWorkflowStreamError() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.workflowEvents,
    const StandardMethodCodec().encodeErrorEnvelope(
      code: 'TEST_STREAM_ERROR',
      message: 'synthetic workflow stream error',
    ),
    (_) => completer.complete(),
  );
  await completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
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

  Future<String> startRecordingSession(RecordingController recording) async {
    recording.beginRecordingStartIntent();
    final sessionId = recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    expect(recording.phase, WorkflowPhase.recording);
    return sessionId;
  }

  test('mid-recording recordingFailed idles, retains the error, and resets '
      'elapsed tracking', () async {
    final harness = await createHarness();
    final sessionId = await startRecordingSession(harness.recording);

    await _emitWorkflowEvent({
      'type': 'recordingFailed',
      'sessionId': sessionId,
      'stage': 'capture',
      'code': 'ENCODER_VIDEO_ERROR',
      'error': 'The encoder ran out of memory.',
    });

    expect(harness.recording.phase, WorkflowPhase.idle);
    expect(harness.recording.errorCode, 'ENCODER_VIDEO_ERROR');
    expect(harness.recording.errorMessage, 'The encoder ran out of memory.');
    expect(harness.recording.isRecording, isFalse);
    // _transitionToIdle stopped the ticker and reset tracking.
    expect(harness.recording.elapsed, Duration.zero);
  });

  test('duplicate recordingFailed is tolerated (second is stale)', () async {
    final harness = await createHarness();
    final sessionId = await startRecordingSession(harness.recording);

    await _emitWorkflowEvent({
      'type': 'recordingFailed',
      'sessionId': sessionId,
      'code': 'RECORDING_ERROR',
      'error': 'first failure',
    });
    await _emitWorkflowEvent({
      'type': 'recordingFailed',
      'sessionId': sessionId,
      'code': 'INTERNAL_ERROR',
      'error': 'duplicate failure',
    });

    // The duplicate must not clobber the original error or re-transition.
    expect(harness.recording.phase, WorkflowPhase.idle);
    expect(harness.recording.errorCode, 'RECORDING_ERROR');
    expect(harness.recording.errorMessage, 'first failure');
  });

  test('recordingFailed during openingPreview is ignored (recording already '
      'finalized)', () async {
    final harness = await createHarness();
    final sessionId = await startRecordingSession(harness.recording);
    await harness.recording.stopRecording();
    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/test.clingfyproj',
    });
    expect(harness.recording.phase, WorkflowPhase.openingPreview);

    await _emitWorkflowEvent({
      'type': 'recordingFailed',
      'sessionId': sessionId,
      'code': 'RECORDING_ERROR',
      'error': 'late failure after finalize',
    });

    expect(harness.recording.phase, WorkflowPhase.openingPreview);
    expect(harness.recording.errorCode, isNull);
    expect(harness.recording.previewPath, '/tmp/test.clingfyproj');
  });

  test('recordingFailed during previewReady is ignored', () async {
    final harness = await createHarness();
    final sessionId = await startRecordingSession(harness.recording);
    await harness.recording.stopRecording();
    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/test.clingfyproj',
    });
    await harness.recording.handlePreviewHostMounted();
    await _emitWorkflowEvent({
      'type': 'previewReady',
      'sessionId': sessionId,
      'path': '/tmp/test.mov',
      'token': 'tok',
    });
    expect(harness.recording.phase, WorkflowPhase.previewReady);

    await _emitWorkflowEvent({
      'type': 'recordingFailed',
      'sessionId': sessionId,
      'code': 'RECORDING_ERROR',
      'error': 'late failure during preview',
    });

    expect(harness.recording.phase, WorkflowPhase.previewReady);
    expect(harness.recording.errorCode, isNull);
  });

  test('recordingFinalized without a projectPath synthesizes '
      'RECORDING_FINALIZE_ERROR', () async {
    final harness = await createHarness();
    final sessionId = await startRecordingSession(harness.recording);
    await harness.recording.stopRecording();

    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
    });

    expect(harness.recording.phase, WorkflowPhase.idle);
    expect(
      harness.recording.errorCode,
      DartSynthesizedErrorCode.recordingFinalizeError,
    );
    expect(harness.recording.errorMessage, 'Missing finalized project path');
  });

  test('duplicate recordingFinalized during openingPreview is ignored and '
      'cannot re-enter the preview flow', () async {
    final harness = await createHarness();
    final sessionId = await startRecordingSession(harness.recording);
    await harness.recording.stopRecording();

    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/first.clingfyproj',
    });
    expect(harness.recording.phase, WorkflowPhase.openingPreview);

    // A duplicate with a different path would previously re-enter
    // _enterPreviewForProject and hijack the open in flight.
    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/second.clingfyproj',
    });

    expect(harness.recording.phase, WorkflowPhase.openingPreview);
    expect(harness.recording.projectPath, '/tmp/first.clingfyproj');
    expect(harness.recording.previewPath, '/tmp/first.clingfyproj');
  });

  test('a workflow stream error does not kill the subscription', () async {
    final harness = await createHarness();

    await _emitWorkflowStreamError();

    // Subsequent events must still be processed (cancelOnError stays
    // false and the onError handler must not throw).
    final sessionId = await startRecordingSession(harness.recording);
    expect(harness.recording.phase, WorkflowPhase.recording);
    expect(harness.recording.sessionId, sessionId);
  });

  group('a stop that fails must not resurrect a finished session', () {
    /// Reproduces the field wedge of 2026-07-27. The camera recorder failed
    /// to finalize; native emitted recordingFailed (which correctly tore the
    /// session down) and then replied to the pending stopRecording call with
    /// the same error 35 ms later. Restoring the pre-stop state there put the
    /// UI back into "recording" over an already-idle native side, and every
    /// subsequent Stop returned NOT_RECORDING and restored it again — eleven
    /// presses in the field, none of which could work.
    testWidgets('a failure event that lands before the stop reply wins', (
      tester,
    ) async {
      final harness = await createHarness();
      final sessionId = await startRecordingSession(harness.recording);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final stopCalled = Completer<void>();
      messenger.setMockMethodCallHandler(
        const MethodChannel(NativeChannel.screenRecorder),
        (call) async {
          if (call.method == 'stopRecording') {
            if (!stopCalled.isCompleted) stopCalled.complete();
            // Native tore the session down and reports the same failure on
            // both surfaces.
            await _emitWorkflowEvent({
              'type': 'recordingFailed',
              'sessionId': sessionId,
              'stage': 'finalize',
              'code': NativeErrorCode.recordingError,
              'error': 'Camera recorder is not active',
            });
            throw PlatformException(
              code: NativeErrorCode.recordingError,
              message: 'Camera recorder is not active',
            );
          }
          return null;
        },
      );

      await harness.recording.stopRecording();
      await tester.pump();

      expect(
        harness.recording.phase,
        WorkflowPhase.idle,
        reason: 'the stop reply must not resurrect a torn-down session',
      );
    });

    testWidgets('NOT_RECORDING reconciles to idle instead of restoring', (
      tester,
    ) async {
      // Native holds no session, so "restore what we had" is always wrong —
      // it guarantees the next Stop fails the same way.
      final harness = await createHarness();
      await startRecordingSession(harness.recording);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel(NativeChannel.screenRecorder),
        (call) async {
          if (call.method == 'stopRecording') {
            throw PlatformException(code: NativeErrorCode.notRecording);
          }
          return null;
        },
      );

      await harness.recording.stopRecording();
      await tester.pump();

      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(harness.recording.errorCode, NativeErrorCode.notRecording);
    });

    testWidgets('a genuine stop failure still restores the live session', (
      tester,
    ) async {
      // The guard must not swallow the case it was written for: if native is
      // still recording, the UI has to stay recording so the user can retry.
      final harness = await createHarness();
      await startRecordingSession(harness.recording);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel(NativeChannel.screenRecorder),
        (call) async {
          if (call.method == 'stopRecording') {
            throw PlatformException(
              code: NativeErrorCode.recordingError,
              message: 'transient stop failure',
            );
          }
          return null;
        },
      );

      await harness.recording.stopRecording();
      await tester.pump();

      expect(
        harness.recording.phase,
        WorkflowPhase.recording,
        reason: 'a live session must remain stoppable',
      );

      // Restoring a live session restarts the elapsed ticker — which is the
      // point — so tear the session down before the test ends rather than
      // leaving a pending timer.
      await _emitWorkflowEvent({
        'type': 'recordingFailed',
        'sessionId': harness.recording.sessionId,
        'code': NativeErrorCode.recordingError,
        'error': 'cleanup',
      });
      await tester.pump();
      expect(harness.recording.phase, WorkflowPhase.idle);
    });
  });
}
