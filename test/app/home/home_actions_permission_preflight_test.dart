import 'dart:async';

import 'package:clingfy/app/shell/app_scope.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/settings/widgets/app_settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/native_test_setup.dart';

class _Harness {
  _Harness({
    required this.actions,
    required this.context,
    required this.countdown,
    required this.recording,
    required this.device,
    required this.overlay,
    required this.permissions,
    required this.settings,
    required this.player,
    required this.post,
    required this.license,
    required this.uiState,
    required this.calls,
  });

  final HomeActions actions;
  final BuildContext context;
  final CountdownController countdown;
  final RecordingController recording;
  final DeviceController device;
  final OverlayController overlay;
  final PermissionsController permissions;
  final SettingsController settings;
  final PlayerController player;
  final PostProcessingController post;
  final LicenseController license;
  final HomeUiState uiState;
  final List<MethodCall> calls;
  bool _disposed = false;

  Iterable<MethodCall> callsFor(String method) =>
      calls.where((call) => call.method == method);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    countdown.dispose();
    recording.dispose();
    device.dispose();
    overlay.dispose();
    permissions.dispose();
    settings.dispose();
    player.dispose();
    post.dispose();
    license.dispose();
    uiState.dispose();
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

  Future<_Harness> createHarness(
    WidgetTester tester, {
    required Map<String, bool> permissionStatus,
    List<Map<String, Object?>> audioSources = const [],
    Map<String, Object?>? storageSnapshot,
  }) async {
    SharedPreferences.setMockInitialValues({});

    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getPermissionStatus':
          return permissionStatus;
        case 'getAudioSources':
          return audioSources;
        case 'getVideoSources':
        case 'getDisplays':
        case 'getAppWindows':
          return <dynamic>[];
        case 'getStorageSnapshot':
          return storageSnapshot ??
              <String, Object?>{
                'systemTotalBytes': 500 * 1024 * 1024 * 1024,
                'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
                'recordingsBytes': 4 * 1024 * 1024,
                'tempBytes': 2 * 1024 * 1024,
                'logsBytes': 512 * 1024,
                'recordingsPath': '/tmp/Clingfy/Recordings',
                'tempPath': '/tmp/Clingfy/Temp',
                'logsPath': '/tmp/Clingfy/Logs',
                'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
                'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
              };
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        case 'requestScreenRecordingPermission':
        case 'requestMicrophonePermission':
        case 'requestCameraPermission':
          return false;
        case 'setAppWindowTarget':
        case 'setAudioSource':
        case 'setVideoSource':
        case 'setRecordingIndicatorPinned':
        case 'setDisplayTargetMode':
        case 'setPreRecordingBarEnabled':
        case 'setPreRecordingBarVisible':
        case 'togglePreRecordingBar':
        case 'setExcludeRecorderApp':
        case 'setExcludeMicFromSystemAudio':
        case 'setCursorHighlightEnabled':
        case 'setCursorHighlightLinkedToRecording':
        case 'setOverlayEnabled':
        case 'setCameraOverlayShape':
        case 'setCameraOverlaySize':
        case 'setCameraOverlayShadow':
        case 'setCameraOverlayBorder':
        case 'setCameraOverlayBorderWidth':
        case 'setCameraOverlayBorderColor':
        case 'setCameraOverlayRoundness':
        case 'setCameraOverlayOpacity':
        case 'setOverlayMirror':
        case 'setChromaKeyEnabled':
        case 'setChromaKeyStrength':
        case 'setChromaKeyColor':
        case 'setCameraOverlayHighlightStrength':
        case 'setCameraOverlayPosition':
        case 'setCameraOverlayCustomPosition':
        case 'setOverlayLinkedToRecording':
        case 'setFileNameTemplate':
        case 'cacheLocalizedStrings':
        case 'setAudioMix':
        case 'previewOpen':
        case 'previewClose':
        case 'previewPlay':
        case 'previewPause':
        case 'previewSeekTo':
        case 'previewPeekTo':
        case 'inlinePreviewStop':
        case 'startRecording':
        case 'stopRecording':
        case 'openAccessibilitySettings':
        case 'openSystemSettings':
        case 'openScreenRecordingSettings':
        case 'checkForUpdates':
          return null;
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
    final player = PlayerController(nativeBridge: nativeBridge);
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
    final scope = HomeScope(
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
    );
    final actions = HomeActions(scope: scope);

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        routes: {
          AppSettingsView.routeName: (context) =>
              AppSettingsView(controller: settings),
          AppSettingsView.storageRouteName: (context) => AppSettingsView(
            controller: settings,
            initialSection: SettingsSection.storage,
          ),
        },
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            MacosTheme(data: MacosThemeData.light(), child: child!),
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final harness = _Harness(
      actions: actions,
      context: context,
      countdown: countdown,
      recording: recording,
      device: device,
      overlay: overlay,
      permissions: permissions,
      settings: settings,
      player: player,
      post: post,
      license: license,
      uiState: uiState,
      calls: calls,
    );
    addTearDown(harness.dispose);
    return harness;
  }

  testWidgets('hard blocker prevents countdown and native start', (
    tester,
  ) async {
    final harness = await createHarness(
      tester,
      permissionStatus: const {
        'screenRecording': false,
        'microphone': true,
        'camera': true,
        'accessibility': true,
      },
    );

    unawaited(harness.actions.toggleRecording(harness.context));
    await tester.pumpAndSettle();

    expect(find.text('Grant permissions'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(harness.countdown.isActive, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(harness.callsFor('startRecording'), isEmpty);
    harness.dispose();
  });

  testWidgets(
    'optional gaps and record without missing features starts with overrides',
    (tester) async {
      final harness = await createHarness(
        tester,
        permissionStatus: const {
          'screenRecording': true,
          'microphone': false,
          'camera': true,
          'accessibility': true,
        },
        audioSources: const [
          {'id': 'mic-1', 'name': 'Built-in Mic'},
        ],
      );

      await harness.device.setAudioSource('mic-1');
      unawaited(harness.actions.toggleRecording(harness.context));
      await tester.pumpAndSettle();

      expect(find.text('Record without missing features'), findsOneWidget);

      await tester.tap(find.text('Record without missing features'));
      await tester.pumpAndSettle();

      final startCall = harness.callsFor('startRecording').single;
      final args = Map<String, dynamic>.from(
        startCall.arguments! as Map<dynamic, dynamic>,
      );
      expect(args['disableMicrophone'], isTrue);
      expect(args['disableCameraOverlay'], isFalse);
      expect(args['disableCursorHighlight'], isFalse);
      harness.dispose();
    },
  );

  testWidgets(
    'grant path requests permissions and returns to idle without auto-start',
    (tester) async {
      final harness = await createHarness(
        tester,
        permissionStatus: const {
          'screenRecording': false,
          'microphone': true,
          'camera': true,
          'accessibility': true,
        },
      );

      unawaited(harness.actions.toggleRecording(harness.context));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Grant permissions'));
      await tester.pumpAndSettle();

      expect(
        harness.callsFor('requestScreenRecordingPermission'),
        hasLength(1),
      );
      expect(harness.callsFor('openScreenRecordingSettings'), hasLength(1));
      expect(harness.callsFor('startRecording'), isEmpty);
      expect(harness.countdown.isActive, isFalse);
      expect(harness.recording.phase, isNot(equals(WorkflowPhase.recording)));
      harness.dispose();
    },
  );

  testWidgets('countdown starts only after preflight resolution', (
    tester,
  ) async {
    final harness = await createHarness(
      tester,
      permissionStatus: const {
        'screenRecording': true,
        'microphone': false,
        'camera': true,
        'accessibility': true,
      },
      audioSources: const [
        {'id': 'mic-1', 'name': 'Built-in Mic'},
      ],
    );

    await harness.settings.recording.updateCountdownEnabled(true);
    await harness.settings.recording.updateCountdownDuration(1);
    await harness.device.setAudioSource('mic-1');

    unawaited(harness.actions.toggleRecording(harness.context));
    await tester.pumpAndSettle();

    expect(harness.countdown.isActive, isFalse);
    expect(harness.callsFor('startRecording'), isEmpty);

    await tester.tap(find.text('Record without missing features'));
    await tester.pump();

    expect(harness.countdown.isActive, isTrue);
    expect(harness.callsFor('startRecording'), isEmpty);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final startCall = harness.callsFor('startRecording').single;
    final args = Map<String, dynamic>.from(
      startCall.arguments! as Map<dynamic, dynamic>,
    );
    expect(args['disableMicrophone'], isTrue);
    harness.dispose();
  });

  testWidgets('storage warning shows record anyway flow before native start', (
    tester,
  ) async {
    final harness = await createHarness(
      tester,
      permissionStatus: const {
        'screenRecording': true,
        'microphone': true,
        'camera': true,
        'accessibility': true,
      },
      storageSnapshot: <String, Object?>{
        'systemTotalBytes': 500 * 1024 * 1024 * 1024,
        'systemAvailableBytes': 15 * 1024 * 1024 * 1024,
        'recordingsBytes': 4 * 1024 * 1024,
        'tempBytes': 2 * 1024 * 1024,
        'logsBytes': 512 * 1024,
        'recordingsPath': '/tmp/Clingfy/Recordings',
        'tempPath': '/tmp/Clingfy/Temp',
        'logsPath': '/tmp/Clingfy/Logs',
        'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
        'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
      },
    );

    unawaited(harness.actions.toggleRecording(harness.context));
    await tester.pumpAndSettle();

    expect(find.text('Record anyway'), findsOneWidget);
    expect(harness.callsFor('startRecording'), isEmpty);

    await tester.tap(find.text('Record anyway'));
    await tester.pumpAndSettle();

    expect(harness.callsFor('startRecording'), hasLength(1));
    final startCall = harness.callsFor('startRecording').single;
    final args = Map<String, dynamic>.from(
      startCall.arguments! as Map<dynamic, dynamic>,
    );
    expect(args['allowLowStorageBypass'], isFalse);
  });

  testWidgets(
    'single-window mode with no selected window shows a persistent blocker and does not start',
    (tester) async {
      final harness = await createHarness(
        tester,
        permissionStatus: const {
          'screenRecording': true,
          'microphone': true,
          'camera': true,
          'accessibility': true,
        },
      );

      await harness.actions.setDisplayTargetMode(
        DisplayTargetMode.singleAppWindow,
      );

      unawaited(harness.actions.toggleRecording(harness.context));
      await tester.pumpAndSettle();

      expect(harness.callsFor('startRecording'), isEmpty);
      expect(harness.countdown.isActive, isFalse);
      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(harness.uiState.errorMessage, NativeErrorCode.noWindowSelected);
      expect(find.text('Grant permissions'), findsNothing);
    },
  );

  testWidgets(
    'area-recording mode with no selected area shows a persistent blocker and does not start',
    (tester) async {
      final harness = await createHarness(
        tester,
        permissionStatus: const {
          'screenRecording': true,
          'microphone': true,
          'camera': true,
          'accessibility': true,
        },
      );

      await harness.actions.setDisplayTargetMode(
        DisplayTargetMode.areaRecording,
      );

      unawaited(harness.actions.toggleRecording(harness.context));
      await tester.pumpAndSettle();

      expect(harness.callsFor('startRecording'), isEmpty);
      expect(harness.countdown.isActive, isFalse);
      expect(harness.recording.phase, WorkflowPhase.idle);
      expect(harness.uiState.errorMessage, NativeErrorCode.noAreaSelected);
      expect(find.text('Grant permissions'), findsNothing);
    },
  );

  testWidgets('critical storage opens storage settings instead of starting', (
    tester,
  ) async {
    final harness = await createHarness(
      tester,
      permissionStatus: const {
        'screenRecording': true,
        'microphone': true,
        'camera': true,
        'accessibility': true,
      },
      storageSnapshot: <String, Object?>{
        'systemTotalBytes': 500 * 1024 * 1024 * 1024,
        'systemAvailableBytes': 5 * 1024 * 1024 * 1024,
        'recordingsBytes': 4 * 1024 * 1024,
        'tempBytes': 2 * 1024 * 1024,
        'logsBytes': 512 * 1024,
        'recordingsPath': '/tmp/Clingfy/Recordings',
        'tempPath': '/tmp/Clingfy/Temp',
        'logsPath': '/tmp/Clingfy/Logs',
        'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
        'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
      },
    );

    unawaited(harness.actions.toggleRecording(harness.context));
    await tester.pumpAndSettle();

    expect(find.text('Open Storage Settings'), findsOneWidget);
    expect(find.byKey(const Key('storage_dialog_close')), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);

    await tester.tap(find.text('Open Storage Settings'));
    await tester.pumpAndSettle();

    expect(
      find.text('Recording space, internal usage, and disk health.'),
      findsOneWidget,
    );
    expect(harness.callsFor('startRecording'), isEmpty);
  });

  testWidgets('critical storage bypass starts recording in dev mode', (
    tester,
  ) async {
    final harness = await createHarness(
      tester,
      permissionStatus: const {
        'screenRecording': true,
        'microphone': true,
        'camera': true,
        'accessibility': true,
      },
      storageSnapshot: <String, Object?>{
        'systemTotalBytes': 500 * 1024 * 1024 * 1024,
        'systemAvailableBytes': 5 * 1024 * 1024 * 1024,
        'recordingsBytes': 4 * 1024 * 1024,
        'tempBytes': 2 * 1024 * 1024,
        'logsBytes': 512 * 1024,
        'recordingsPath': '/tmp/Clingfy/Recordings',
        'tempPath': '/tmp/Clingfy/Temp',
        'logsPath': '/tmp/Clingfy/Logs',
        'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
        'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
      },
    );

    unawaited(harness.actions.toggleRecording(harness.context));
    await tester.pumpAndSettle();

    expect(find.text('Bypass and record'), findsOneWidget);
    expect(harness.callsFor('startRecording'), isEmpty);

    await tester.tap(find.text('Bypass and record'));
    await tester.pumpAndSettle();

    final startCall = harness.callsFor('startRecording').single;
    final args = Map<String, dynamic>.from(
      startCall.arguments! as Map<dynamic, dynamic>,
    );
    expect(args['allowLowStorageBypass'], isTrue);
  });
}
