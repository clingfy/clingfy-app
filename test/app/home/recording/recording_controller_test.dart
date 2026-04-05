import 'dart:async';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_helpers/native_test_setup.dart';

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
    return (recording: recording, settings: settings);
  }

  test(
    'start intent enters startingRecording and allocates sessionId',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      expect(harness.recording.phase, WorkflowPhase.idle);

      harness.recording.beginRecordingStartIntent();

      expect(harness.recording.phase, WorkflowPhase.startingRecording);
      expect(harness.recording.sessionId, isNotNull);
    },
  );

  test(
    'recordingStarted transitions to recording for active session',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;

      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });

      expect(harness.recording.phase, WorkflowPhase.recording);
      expect(harness.recording.isRecording, isTrue);
    },
  );

  test(
    'pause then resume returns to recording and stop still finalizes',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });

      final pauseFuture = harness.recording.pauseRecording();
      expect(harness.recording.pauseResumeInFlight, isTrue);
      await _emitWorkflowEvent({
        'type': 'recordingPaused',
        'sessionId': sessionId,
      });
      await pauseFuture;

      expect(harness.recording.phase, WorkflowPhase.pausedRecording);
      expect(harness.recording.isPaused, isTrue);
      expect(harness.recording.isRecording, isTrue);
      expect(harness.recording.pauseResumeInFlight, isFalse);

      final resumeFuture = harness.recording.resumeRecording();
      expect(harness.recording.pauseResumeInFlight, isTrue);
      await _emitWorkflowEvent({
        'type': 'recordingResumed',
        'sessionId': sessionId,
      });
      await resumeFuture;

      expect(harness.recording.phase, WorkflowPhase.recording);
      expect(harness.recording.isActivelyRecording, isTrue);
      expect(harness.recording.pauseResumeInFlight, isFalse);

      await harness.recording.stopRecording();

      expect(harness.recording.phase, WorkflowPhase.finalizingRecording);
    },
  );

  test('stopRecording works while paused', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });

    final pauseFuture = harness.recording.pauseRecording();
    await _emitWorkflowEvent({
      'type': 'recordingPaused',
      'sessionId': sessionId,
    });
    await pauseFuture;

    expect(harness.recording.phase, WorkflowPhase.pausedRecording);

    await harness.recording.stopRecording();

    expect(harness.recording.phase, WorkflowPhase.finalizingRecording);
    expect(harness.recording.showHeroPanel, isTrue);
  });

  test('invalid pause and resume requests are ignored safely', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    var pauseCalls = 0;
    var resumeCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'pauseRecording':
          pauseCalls += 1;
          return null;
        case 'resumeRecording':
          resumeCalls += 1;
          return null;
        case 'getRecordingCapabilities':
          return <String, dynamic>{
            'canPauseResume': true,
            'backend': 'avfoundation',
            'strategy': 'av_file_output',
          };
        default:
          return null;
      }
    });

    await harness.recording.pauseRecording();
    await harness.recording.resumeRecording();

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });

    await harness.recording.resumeRecording();

    final pauseFuture = harness.recording.pauseRecording();
    await _emitWorkflowEvent({
      'type': 'recordingPaused',
      'sessionId': sessionId,
    });
    await pauseFuture;

    await harness.recording.pauseRecording();

    expect(pauseCalls, 1);
    expect(resumeCalls, 0);
    expect(harness.recording.phase, WorkflowPhase.pausedRecording);
  });

  test('duplicate paused and resumed events keep stable state', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });

    await _emitWorkflowEvent({
      'type': 'recordingPaused',
      'sessionId': sessionId,
    });
    final elapsedWhilePaused = harness.recording.elapsed;

    await _emitWorkflowEvent({
      'type': 'recordingPaused',
      'sessionId': sessionId,
    });

    expect(harness.recording.phase, WorkflowPhase.pausedRecording);
    expect(harness.recording.elapsed, elapsedWhilePaused);

    await _emitWorkflowEvent({
      'type': 'recordingResumed',
      'sessionId': sessionId,
    });
    await _emitWorkflowEvent({
      'type': 'recordingResumed',
      'sessionId': sessionId,
    });

    expect(harness.recording.phase, WorkflowPhase.recording);
    expect(harness.recording.isActivelyRecording, isTrue);
  });

  test(
    'stop transitions through stopping to finalizing without idling',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });

      await harness.recording.stopRecording();

      expect(harness.recording.phase, WorkflowPhase.finalizingRecording);
      expect(harness.recording.showHeroPanel, isTrue);
      expect(harness.recording.showPreviewShell, isFalse);
    },
  );

  test(
    'recordingFinalized opens preview flow instead of returning to idle',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });
      await harness.recording.stopRecording();

      await _emitWorkflowEvent({
        'type': 'recordingFinalized',
        'sessionId': sessionId,
        'projectPath': '/tmp/test.clingfyproj',
      });

      expect(harness.recording.phase, WorkflowPhase.openingPreview);
      expect(harness.recording.previewPath, '/tmp/test.clingfyproj');
      expect(harness.recording.showPreviewShell, isTrue);
      expect(harness.recording.showPreviewLoadingOverlay, isTrue);
    },
  );

  test(
    'recordingFinalized is not clobbered when stopRecording returns later',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final stopCompleter = Completer<void>();
      messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
        switch (call.method) {
          case 'stopRecording':
            await stopCompleter.future;
            return null;
          default:
            return null;
        }
      });

      final stopFuture = harness.recording.stopRecording();
      await Future<void>.delayed(Duration.zero);
      expect(harness.recording.phase, WorkflowPhase.finalizingRecording);

      await _emitWorkflowEvent({
        'type': 'recordingFinalized',
        'sessionId': sessionId,
        'projectPath': '/tmp/test.clingfyproj',
      });
      expect(harness.recording.phase, WorkflowPhase.openingPreview);
      expect(harness.recording.showPreviewShell, isTrue);

      stopCompleter.complete();
      await stopFuture;

      expect(harness.recording.phase, WorkflowPhase.openingPreview);
      expect(harness.recording.showPreviewShell, isTrue);
    },
  );

  test(
    'preview host mounted transitions openingPreview to previewLoading',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });
      await harness.recording.stopRecording();
      await _emitWorkflowEvent({
        'type': 'recordingFinalized',
        'sessionId': sessionId,
        'projectPath': '/tmp/test.clingfyproj',
      });

      await harness.recording.handlePreviewHostMounted();

      expect(harness.recording.phase, WorkflowPhase.previewLoading);
      expect(harness.recording.showPreviewLoadingOverlay, isTrue);
      expect(harness.recording.showPreviewSurface, isFalse);
    },
  );

  test('previewReady transitions previewLoading to previewReady', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
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
      'token': 'preview_token',
    });

    expect(harness.recording.phase, WorkflowPhase.previewReady);
    expect(harness.recording.showPreviewControls, isTrue);
    expect(harness.recording.canInteractWithPreview, isTrue);
    expect(harness.recording.showPreviewSurface, isTrue);
  });

  test(
    'previewPreparing with sessionId is accepted during preview open',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });
      await harness.recording.stopRecording();
      await _emitWorkflowEvent({
        'type': 'recordingFinalized',
        'sessionId': sessionId,
        'projectPath': '/tmp/test.clingfyproj',
      });
      await harness.recording.handlePreviewHostMounted();

      await _emitWorkflowEvent({
        'type': 'previewPreparing',
        'sessionId': sessionId,
        'path': '/tmp/test.mov',
        'token': 'preview_token',
      });

      expect(harness.recording.phase, WorkflowPhase.previewLoading);
      expect(harness.recording.previewToken, 'preview_token');
    },
  );

  test('close preview returns to idle only after previewClosed', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
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
      'token': 'preview_token',
    });

    await harness.recording.closePreview();
    expect(harness.recording.phase, WorkflowPhase.closingPreview);

    await _emitWorkflowEvent({
      'type': 'previewClosed',
      'sessionId': sessionId,
      'token': 'preview_token',
      'reason': 'flutterRequest',
    });

    expect(harness.recording.phase, WorkflowPhase.idle);
    expect(harness.recording.sessionId, isNull);
  });

  test('previewClosed during previewReady is ignored', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
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
      'token': 'preview_token',
    });

    await _emitWorkflowEvent({
      'type': 'previewClosed',
      'sessionId': sessionId,
      'token': 'preview_token',
      'reason': 'deinit',
    });

    expect(harness.recording.phase, WorkflowPhase.previewReady);
    expect(harness.recording.sessionId, sessionId);
    expect(harness.recording.previewPath, '/tmp/test.mov');
  });

  test('previewClosed during openingPreview is ignored', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    await harness.recording.stopRecording();
    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/test.clingfyproj',
    });

    await _emitWorkflowEvent({
      'type': 'previewClosed',
      'sessionId': sessionId,
      'token': 'preview_token',
      'reason': 'dispose',
    });

    expect(harness.recording.phase, WorkflowPhase.openingPreview);
    expect(harness.recording.sessionId, sessionId);
    expect(harness.recording.previewPath, '/tmp/test.clingfyproj');
  });

  test('previewClosed during previewLoading is ignored', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    await harness.recording.stopRecording();
    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/test.clingfyproj',
    });
    await harness.recording.handlePreviewHostMounted();

    await _emitWorkflowEvent({
      'type': 'previewClosed',
      'sessionId': sessionId,
      'token': 'preview_token',
      'reason': 'reset',
    });

    expect(harness.recording.phase, WorkflowPhase.previewLoading);
    expect(harness.recording.sessionId, sessionId);
    expect(harness.recording.previewPath, '/tmp/test.clingfyproj');
  });

  test(
    'export start and finish round-trip between previewReady and exporting',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });
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
        'token': 'preview_token',
      });

      harness.recording.enterExporting();
      expect(harness.recording.phase, WorkflowPhase.exporting);
      expect(harness.recording.showPreviewShell, isTrue);
      expect(harness.recording.showPreviewControls, isFalse);

      harness.recording.finishExporting();
      expect(harness.recording.phase, WorkflowPhase.previewReady);
    },
  );

  test('stale workflow events are ignored', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;

    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': 'rec_stale',
    });
    expect(harness.recording.phase, WorkflowPhase.startingRecording);

    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    await harness.recording.stopRecording();

    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': 'rec_stale',
      'projectPath': '/tmp/stale.clingfyproj',
    });

    expect(harness.recording.phase, WorkflowPhase.finalizingRecording);
    expect(harness.recording.previewPath, isNull);
  });

  test('preview events without sessionId are ignored', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    await harness.recording.stopRecording();
    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': '/tmp/test.clingfyproj',
    });
    await harness.recording.handlePreviewHostMounted();

    await _emitWorkflowEvent({
      'type': 'previewReady',
      'path': '/tmp/test.mov',
      'token': 'preview_token',
    });

    expect(harness.recording.phase, WorkflowPhase.previewLoading);
    expect(harness.recording.previewToken, isNull);
  });

  test('phase-incompatible previewReady is ignored', () async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.settings.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;

    await _emitWorkflowEvent({
      'type': 'previewReady',
      'sessionId': sessionId,
      'path': '/tmp/test.mov',
      'token': 'preview_token',
    });

    expect(harness.recording.phase, WorkflowPhase.startingRecording);
    expect(harness.recording.previewPath, isNull);
  });

  test(
    'preview failure transitions through closing and idles after previewClosed',
    () async {
      final harness = await createHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.settings.dispose);

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });
      await harness.recording.stopRecording();
      await _emitWorkflowEvent({
        'type': 'recordingFinalized',
        'sessionId': sessionId,
        'projectPath': '/tmp/test.clingfyproj',
      });
      await harness.recording.handlePreviewHostMounted();

      await _emitWorkflowEvent({
        'type': 'previewFailed',
        'sessionId': sessionId,
        'path': '/tmp/test.mov',
        'token': 'preview_token',
        'reason': 'assetInvalid',
        'error': 'Asset invalid',
      });

      expect(harness.recording.phase, WorkflowPhase.closingPreview);
      expect(harness.recording.errorCode, 'assetInvalid');

      await _emitWorkflowEvent({
        'type': 'previewClosed',
        'sessionId': sessionId,
        'token': 'preview_token',
        'reason': 'failureCleanup',
      });

      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(harness.recording.errorCode, 'assetInvalid');
    },
  );
}
