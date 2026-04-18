import 'dart:async';

import 'package:clingfy/app/home/home_bindings.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/shell/app_scope.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

Future<void> _emitNativeMethod(String method, [Object? arguments]) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.screenRecorder,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) => completer.complete(),
  );
  await completer.future;
}

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

class _Harness {
  _Harness({
    required this.bindings,
    required this.countdown,
    required this.device,
    required this.license,
    required this.overlay,
    required this.permissions,
    required this.player,
    required this.post,
    required this.recording,
    required this.settings,
    required this.uiState,
  });

  final HomeBindings bindings;
  final CountdownController countdown;
  final DeviceController device;
  final LicenseController license;
  final OverlayController overlay;
  final PermissionsController permissions;
  final PlayerController player;
  final PostProcessingController post;
  final RecordingController recording;
  final SettingsController settings;
  final HomeUiState uiState;

  void dispose() {
    bindings.unbind();
    recording.dispose();
    player.dispose();
    device.dispose();
    overlay.dispose();
    permissions.dispose();
    post.dispose();
    license.dispose();
    countdown.dispose();
    uiState.dispose();
    settings.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  Future<_Harness> createHarness({
    Future<void> Function(
      CountdownController countdown,
      RecordingController recording,
    )?
    onToggleRecording,
    Future<void> Function(String projectPath)? onOpenExternalProject,
    Future<void> Function(String path)? onRecordingFinalized,
    void Function(String projectPath)? onExternalProjectOpenFailed,
  }) async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    final player = PlayerController(nativeBridge: nativeBridge)
      ..bindWorkflow(recording);
    final device = DeviceController(nativeBridge: nativeBridge);
    final overlay = OverlayController(bridge: nativeBridge);
    final permissions = PermissionsController(bridge: nativeBridge);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    final license = LicenseController();
    final countdown = CountdownController();
    final uiState = HomeUiState();
    final bindings = HomeBindings(
      scope: HomeScope(
        app: AppScope(nativeBridge: nativeBridge, settings: settings),
        recording: recording,
        player: player,
        devices: device,
        overlay: overlay,
        permissions: permissions,
        post: post,
        license: license,
        countdown: countdown,
        uiState: uiState,
        prefsStore: HomePrefsStore(),
      ),
      onToggleRecording: () async {
        await onToggleRecording?.call(countdown, recording);
      },
      onOpenExternalProject: (projectPath) async {
        await onOpenExternalProject?.call(projectPath);
      },
      onRecordingFinalized: (path) async {
        await onRecordingFinalized?.call(path);
      },
      onExternalProjectOpenFailed: (projectPath) {
        onExternalProjectOpenFailed?.call(projectPath);
      },
      onExportProgress: (_) {},
      onHandleNativeBarAction: (_, __) {},
      onHandleNativeSelectionChanged: (_, __) {},
      onUpdateNativeBarState: () {},
    );

    return _Harness(
      bindings: bindings,
      countdown: countdown,
      device: device,
      license: license,
      overlay: overlay,
      permissions: permissions,
      player: player,
      post: post,
      recording: recording,
      settings: settings,
      uiState: uiState,
    );
  }

  test(
    'indicatorPauseTapped pauses active recording through HomeBindings',
    () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);

      await harness.recording.refreshPauseResumeCapabilities();

      var pauseCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
        switch (call.method) {
          case 'pauseRecording':
            pauseCalls += 1;
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

      harness.recording.beginRecordingStartIntent();
      final sessionId = harness.recording.sessionId!;
      await _emitWorkflowEvent({
        'type': 'recordingStarted',
        'sessionId': sessionId,
      });

      harness.bindings.bind();

      await _emitNativeMethod(NativeToFlutterMethod.indicatorPauseTapped);
      await Future<void>.delayed(Duration.zero);

      expect(pauseCalls, 1);
      expect(harness.recording.pauseResumeInFlight, isTrue);
    },
  );

  testWidgets(
    'escape during countdown routes through toggle callback and returns idle',
    (tester) async {
      var toggleCalls = 0;
      final harness = await createHarness(
        onToggleRecording: (countdown, recording) async {
          toggleCalls += 1;
          countdown.cancel();
          recording.cancelPendingStartIntent();
        },
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );

      harness.bindings.bind();
      harness.recording.beginRecordingStartIntent();
      harness.countdown.start(durationSeconds: 5, onFinished: () {});

      expect(harness.recording.phase, WorkflowPhase.startingRecording);
      expect(harness.countdown.isActive, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(toggleCalls, 1);
      expect(harness.countdown.isActive, isFalse);
      expect(harness.recording.phase, WorkflowPhase.idle);
    },
  );

  test('Finder open requests are forwarded through HomeBindings', () async {
    final openedProjects = <String>[];
    final harness = await createHarness(
      onOpenExternalProject: (projectPath) async {
        openedProjects.add(projectPath);
      },
    );
    addTearDown(harness.dispose);

    harness.bindings.bind();

    await _emitWorkflowEvent({
      'type': 'openProjectRequest',
      'projectPath': '/tmp/finder.clingfyproj',
    });
    await Future<void>.delayed(Duration.zero);

    expect(openedProjects, ['/tmp/finder.clingfyproj']);
  });

  test(
    'external project preview open does not trigger recording-finalized side effects',
    () async {
      var finalizedCalls = 0;
      final harness = await createHarness(
        onRecordingFinalized: (_) async {
          finalizedCalls += 1;
        },
      );
      addTearDown(harness.dispose);

      harness.bindings.bind();
      harness.recording.openExistingProject('/tmp/finder.clingfyproj');
      await Future<void>.delayed(Duration.zero);

      expect(harness.recording.phase, WorkflowPhase.openingPreview);
      expect(finalizedCalls, 0);
    },
  );

  test(
    'external project preview failures are forwarded through HomeBindings',
    () async {
      final failedProjects = <String>[];
      final harness = await createHarness(
        onExternalProjectOpenFailed: failedProjects.add,
      );
      addTearDown(harness.dispose);

      harness.bindings.bind();
      harness.recording.openExistingProject('/tmp/finder.clingfyproj');
      final sessionId = harness.recording.sessionId!;

      await _emitWorkflowEvent({
        'type': 'previewFailed',
        'sessionId': sessionId,
        'reason': 'PREVIEW_ERROR',
        'error': 'boom',
      });
      await Future<void>.delayed(Duration.zero);

      expect(failedProjects, ['/tmp/finder.clingfyproj']);
    },
  );

  test('recordingWarning workflow events become warning notices', () async {
    final harness = await createHarness();
    addTearDown(harness.dispose);

    harness.bindings.bind();
    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;

    await _emitWorkflowEvent({
      'type': 'recordingWarning',
      'sessionId': sessionId,
      'message':
          'Selected microphone couldn’t be used. Recording started with the system default microphone.',
    });
    await Future<void>.delayed(Duration.zero);

    expect(harness.recording.phase, WorkflowPhase.startingRecording);
    expect(
      harness.uiState.notice?.message,
      'Selected microphone couldn’t be used. Recording started with the system default microphone.',
    );
    expect(harness.uiState.notice?.tone, HomeUiNoticeTone.warning);
  });
}
