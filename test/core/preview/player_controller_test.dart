import 'dart:async';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
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
}
