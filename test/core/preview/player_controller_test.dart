import 'dart:async';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

Future<void> _emitEvent(String channel, Map<String, Object?> event) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    channel,
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) => completer.complete(),
  );
  await completer.future;
}

Future<void> _emitWorkflowEvent(Map<String, Object?> event) {
  return _emitEvent(NativeChannel.workflowEvents, event);
}

Future<void> _emitPlayerEvent(Map<String, Object?> event) {
  return _emitEvent(NativeChannel.playerEvents, event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  Future<
    ({
      RecordingController recording,
      PlayerController player,
      SettingsController settings,
      List<MethodCall> calls,
      String sessionId,
    })
  >
  createReadyPreviewHarness() async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        case 'getZoomSegments':
        case 'getManualZoomSegments':
          return <dynamic>[];
        default:
          return null;
      }
    });

    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    final player = PlayerController(nativeBridge: nativeBridge)
      ..bindWorkflow(recording);

    recording.beginRecordingStartIntent();
    // Replace generated session with a deterministic one by using the native events.
    final generatedSessionId = recording.sessionId!;

    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': generatedSessionId,
    });
    await recording.stopRecording();
    await _emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': generatedSessionId,
      'projectPath': '/tmp/demo.clingfyproj',
    });
    await recording.handlePreviewHostMounted();
    await _emitWorkflowEvent({
      'type': 'previewPreparing',
      'sessionId': generatedSessionId,
      'path': '/tmp/demo.mov',
      'token': 'preview_token',
    });
    await _emitWorkflowEvent({
      'type': 'previewReady',
      'sessionId': generatedSessionId,
      'path': '/tmp/demo.mov',
      'token': 'preview_token',
    });

    return (
      recording: recording,
      player: player,
      settings: settings,
      calls: calls,
      sessionId: generatedSessionId,
    );
  }

  test('ignores stale player events by sessionId', () async {
    final harness = await createReadyPreviewHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);

    await _emitPlayerEvent({
      'type': 'playerTick',
      'sessionId': 'rec_stale',
      'positionMs': 900,
      'durationMs': 2000,
    });

    expect(harness.player.positionMs, 0);
    expect(harness.player.durationMs, 0);

    await _emitPlayerEvent({
      'type': 'playerTick',
      'sessionId': harness.sessionId,
      'positionMs': 1200,
      'durationMs': 4000,
    });

    expect(harness.player.positionMs, 1200);
    expect(harness.player.durationMs, 4000);
  });

  test(
    'previewCompositionZoomSegments is null until preview is ready',
    () async {
      final nativeBridge = NativeBridge.instance;
      final settings = SettingsController(nativeBridge: nativeBridge);
      await settings.loadPreferences();
      final recording = RecordingController(
        nativeBridge: nativeBridge,
        settings: settings,
      );
      final player = PlayerController(nativeBridge: nativeBridge)
        ..bindWorkflow(recording);

      addTearDown(recording.dispose);
      addTearDown(player.dispose);
      addTearDown(settings.dispose);

      expect(player.previewCompositionZoomSegments, isNull);
    },
  );

  test('playback transport commands include active sessionId', () async {
    final harness = await createReadyPreviewHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);

    await _emitPlayerEvent({
      'type': 'playerTick',
      'sessionId': harness.sessionId,
      'positionMs': 100,
      'durationMs': 1000,
    });

    await harness.player.play();
    await harness.player.pause();
    await harness.player.seekTo(333);

    final previewPlay = harness.calls.where(
      (call) => call.method == 'previewPlay',
    );
    final previewPause = harness.calls.where(
      (call) => call.method == 'previewPause',
    );
    final previewSeekTo = harness.calls.where(
      (call) => call.method == 'previewSeekTo',
    );

    expect(previewPlay, hasLength(1));
    expect(previewPause, hasLength(1));
    expect(previewSeekTo, hasLength(1));
    expect(
      (previewPlay.single.arguments as Map<dynamic, dynamic>)['sessionId'],
      harness.sessionId,
    );
    expect(
      (previewPause.single.arguments as Map<dynamic, dynamic>)['sessionId'],
      harness.sessionId,
    );
    expect(
      (previewSeekTo.single.arguments as Map<dynamic, dynamic>)['sessionId'],
      harness.sessionId,
    );
  });

  test(
    'attaches a clip editor seeded with the raw duration once ready',
    () async {
      final harness = await createReadyPreviewHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.settings.dispose);

      expect(harness.player.clipEditor, isNull);

      await _emitPlayerEvent({
        'type': 'playerTick',
        'sessionId': harness.sessionId,
        'positionMs': 0,
        'durationMs': 5000,
      });

      final editor = harness.player.clipEditor;
      expect(editor, isNotNull);
      // Seeded with the raw recording duration as a single whole-recording clip.
      expect(editor!.recordingDurationMs, 5000);
      expect(editor.clips, hasLength(1));
      expect(editor.hasCuts, isFalse);
    },
  );

  test(
    'starting playback clears a hover-peek so the playhead tracks again',
    () async {
      final harness = await createReadyPreviewHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.settings.dispose);

      // Ready and paused at 1000ms.
      await _emitPlayerEvent({
        'type': 'playerTick',
        'sessionId': harness.sessionId,
        'positionMs': 1000,
        'durationMs': 5000,
      });
      expect(harness.player.positionMs, 1000);

      // Hover the timeline → peeking suppresses position ticks while paused, so
      // the committed playhead stays put even as the preview frame peeks ahead.
      await harness.player.previewPeekTo(2000);
      await _emitPlayerEvent({
        'type': 'playerTick',
        'sessionId': harness.sessionId,
        'positionMs': 2000,
        'durationMs': 5000,
      });
      expect(harness.player.positionMs, 1000);

      // Starting playback must end the peek so ticks flow to the playhead again
      // (the regression: it stayed frozen until the cursor left the timeline).
      await harness.player.play();
      await _emitPlayerEvent({
        'type': 'playerTick',
        'sessionId': harness.sessionId,
        'positionMs': 1500,
        'durationMs': 5000,
      });
      expect(harness.player.positionMs, 1500);
    },
  );

  test(
    'a hover landing during the play() await cannot re-freeze the playhead',
    () async {
      final harness = await createReadyPreviewHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.settings.dispose);

      await _emitPlayerEvent({
        'type': 'playerTick',
        'sessionId': harness.sessionId,
        'positionMs': 1000,
        'durationMs': 5000,
      });

      // Begin playback, then — before the native previewPlay round-trip
      // resolves — a stray hover fires. previewPeekTo must bail because we are
      // already playing; otherwise it would re-arm the peek and freeze ticks.
      final playFuture = harness.player.play();
      await harness.player.previewPeekTo(3000);
      await playFuture;

      expect(harness.player.isPlaying, isTrue);
      await _emitPlayerEvent({
        'type': 'playerTick',
        'sessionId': harness.sessionId,
        'positionMs': 1800,
        'durationMs': 5000,
      });
      expect(harness.player.positionMs, 1800);
    },
  );

  group('previewInvalidated (Windows standby-resume rebuild)', () {
    test('rebuilds the preview in place and restores the transport', () async {
      final harness = await createReadyPreviewHarness();
      addTearDown(harness.recording.dispose);
      addTearDown(harness.player.dispose);
      addTearDown(harness.settings.dispose);

      // Ready and PLAYING at 1500 ms — the state the rebuild must restore.
      await _emitPlayerEvent({
        'type': 'playerTick',
        'sessionId': harness.sessionId,
        'positionMs': 1500,
        'durationMs': 5000,
      });
      await _emitPlayerEvent({
        'type': 'playerState',
        'sessionId': harness.sessionId,
        'state': 'playing',
      });
      await pumpEventQueue();

      // Swap the mock so the reopen returns a NEW texture, and record the
      // rebuild's native traffic separately from the harness setup calls.
      final rebuildCalls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
        rebuildCalls.add(call);
        if (call.method == 'previewOpen') {
          return <String, dynamic>{
            'textureId': 99,
            'width': 1600,
            'height': 900,
            'videoWidth': 1600,
            'videoHeight': 900,
            'sharedHandleOk': true,
          };
        }
        if (call.method == 'getZoomSegments' ||
            call.method == 'getManualZoomSegments') {
          return <dynamic>[];
        }
        return null;
      });

      final rebuiltSessions = <String>[];
      harness.player.onPreviewRebuilt = (sessionId) async {
        rebuiltSessions.add(sessionId);
      };

      await _emitPlayerEvent({
        'type': PlayerEventType.previewInvalidated,
        'sessionId': harness.sessionId,
        'reason': 'systemResume',
      });
      await pumpEventQueue();

      final methods = rebuildCalls.map((c) => c.method).toList();
      // Raw close → open with the same session id. Both must be PRESENT
      // before the ordering check — indexOf returns -1 for a missing
      // method, which would vacuously satisfy lessThan.
      expect(methods, contains('previewClose'));
      expect(methods, contains('previewOpen'));
      expect(
        methods.indexOf('previewClose'),
        lessThan(methods.indexOf('previewOpen')),
      );
      final open = rebuildCalls.singleWhere((c) => c.method == 'previewOpen');
      expect(
        (open.arguments as Map<dynamic, dynamic>)['sessionId'],
        harness.sessionId,
      );
      // The post-processing hook and both editors re-pushed their state.
      expect(rebuiltSessions, [harness.sessionId]);
      expect(methods, contains('previewSetZoomSegments'));
      expect(methods, contains('previewSetClips'));
      // Transport restored: seek back to 1500 ms, then resume playback.
      final seek = rebuildCalls.where((c) => c.method == 'previewSeekTo');
      expect(seek, hasLength(1));
      expect((seek.single.arguments as Map<dynamic, dynamic>)['ms'], 1500);
      expect(methods, contains('previewPlay'));
      // The texture swapped in place — no phase change, no error.
      expect(harness.recording.inlinePreviewTextureId, 99);
      expect(
        harness.recording.inlinePreviewTextureAspect,
        closeTo(1600 / 900, 1e-9),
      );
      expect(harness.recording.phase, WorkflowPhase.previewReady);
      expect(harness.player.blockingError, isNull);
    });

    test(
      'a paused preview is restored PAUSED (native Open auto-plays)',
      () async {
        final harness = await createReadyPreviewHarness();
        addTearDown(harness.recording.dispose);
        addTearDown(harness.player.dispose);
        addTearDown(harness.settings.dispose);

        // Ready and PAUSED at 1500 ms — no playerState "playing" ever fired.
        await _emitPlayerEvent({
          'type': 'playerTick',
          'sessionId': harness.sessionId,
          'positionMs': 1500,
          'durationMs': 5000,
        });
        expect(harness.player.isPlaying, isFalse);

        final rebuildCalls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
          rebuildCalls.add(call);
          if (call.method == 'previewOpen') {
            return <String, dynamic>{
              'textureId': 55,
              'width': 1600,
              'height': 900,
              'videoWidth': 1600,
              'videoHeight': 900,
              'sharedHandleOk': true,
            };
          }
          if (call.method == 'getZoomSegments' ||
              call.method == 'getManualZoomSegments') {
            return <dynamic>[];
          }
          return null;
        });

        await _emitPlayerEvent({
          'type': PlayerEventType.previewInvalidated,
          'sessionId': harness.sessionId,
          'reason': 'systemResume',
        });
        await pumpEventQueue();

        final methods = rebuildCalls.map((c) => c.method).toList();
        // Windows PreviewEngine::Open() auto-plays the fresh session — the
        // rebuild must counter it with an explicit previewPause, and it must
        // NOT send previewPlay for a preview the user left paused.
        expect(methods, contains('previewSeekTo'));
        expect(methods, contains('previewPause'));
        expect(methods, isNot(contains('previewPlay')));
        expect(harness.player.isPlaying, isFalse);
      },
    );

    test(
      'previewInvalidated during previewLoading is ignored without an error',
      () async {
        // Build the workflow only as far as previewLoading — the normal open
        // flow is still running, so a resume must neither race it with a
        // close/reopen nor surface a blocking error.
        final calls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getExcludeRecorderApp':
              return false;
            case 'getExcludeMicFromSystemAudio':
              return true;
            case 'getZoomSegments':
            case 'getManualZoomSegments':
              return <dynamic>[];
            default:
              return null;
          }
        });

        final nativeBridge = NativeBridge.instance;
        final settings = SettingsController(nativeBridge: nativeBridge);
        await settings.loadPreferences();
        final recording = RecordingController(
          nativeBridge: nativeBridge,
          settings: settings,
        );
        final player = PlayerController(nativeBridge: nativeBridge)
          ..bindWorkflow(recording);
        addTearDown(recording.dispose);
        addTearDown(player.dispose);
        addTearDown(settings.dispose);

        recording.beginRecordingStartIntent();
        final sessionId = recording.sessionId!;
        await _emitWorkflowEvent({
          'type': 'recordingStarted',
          'sessionId': sessionId,
        });
        await recording.stopRecording();
        await _emitWorkflowEvent({
          'type': 'recordingFinalized',
          'sessionId': sessionId,
          'projectPath': '/tmp/demo.clingfyproj',
        });
        await recording.handlePreviewHostMounted();
        expect(recording.phase, WorkflowPhase.previewLoading);

        final callsBefore = calls.length;
        await _emitPlayerEvent({
          'type': PlayerEventType.previewInvalidated,
          'sessionId': sessionId,
          'reason': 'systemResume',
        });
        await pumpEventQueue();

        expect(calls.length, callsBefore);
        expect(player.blockingError, isNull);
        expect(recording.phase, WorkflowPhase.previewLoading);
      },
    );

    test(
      'a stale previewInvalidated never touches the active preview',
      () async {
        final harness = await createReadyPreviewHarness();
        addTearDown(harness.recording.dispose);
        addTearDown(harness.player.dispose);
        addTearDown(harness.settings.dispose);

        final callsBefore = harness.calls.length;
        await _emitPlayerEvent({
          'type': PlayerEventType.previewInvalidated,
          'sessionId': 'rec_stale',
          'reason': 'systemResume',
        });
        await pumpEventQueue();

        expect(harness.calls.length, callsBefore);
        expect(harness.player.blockingError, isNull);
      },
    );

    test(
      'a failed rebuild surfaces a blocking error instead of a frozen frame',
      () async {
        final harness = await createReadyPreviewHarness();
        addTearDown(harness.recording.dispose);
        addTearDown(harness.player.dispose);
        addTearDown(harness.settings.dispose);

        // The harness mock answers previewOpen with null (the macOS shape):
        // no texture comes back, so the rebuild must report failure rather
        // than leave a dead texture on screen.
        await _emitPlayerEvent({
          'type': PlayerEventType.previewInvalidated,
          'sessionId': harness.sessionId,
          'reason': 'systemResume',
        });
        await pumpEventQueue();

        expect(harness.player.blockingError, isNotNull);
        expect(
          harness.player.blockingErrorCode,
          NativeErrorCode.previewOpenError,
        );
        expect(harness.recording.phase, WorkflowPhase.previewReady);
      },
    );
  });
}
