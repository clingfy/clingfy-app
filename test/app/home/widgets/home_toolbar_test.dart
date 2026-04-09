import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/widgets/desktop_toolbar.dart';
import 'package:clingfy/app/home/widgets/home_toolbar.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

import '../../../test_helpers/native_test_setup.dart';

class _ToolbarPostProcessingController extends PostProcessingController {
  _ToolbarPostProcessingController._({
    required this.settings,
    required this.player,
  }) : super(
         settings: settings,
         player: player,
         channel: NativeBridge.instance,
       );

  factory _ToolbarPostProcessingController() {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    final player = PlayerController(nativeBridge: NativeBridge.instance);
    final controller = _ToolbarPostProcessingController._(
      settings: settings,
      player: player,
    );
    controller.attachToRecording(
      sessionId: 'rec_test_session',
      projectPath: '/tmp/original.clingfyproj',
    );
    return controller;
  }

  final SettingsController settings;
  final PlayerController player;

  @override
  void dispose() {
    super.dispose();
    player.dispose();
    settings.dispose();
  }
}

class _FakeDeviceController extends DeviceController {
  _FakeDeviceController() : super(nativeBridge: NativeBridge.instance);

  String? _testErrorMessage;

  @override
  String? get errorMessage => _testErrorMessage;

  void setTestError(String? value) {
    _testErrorMessage = value;
    notifyListeners();
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

  testWidgets('renders localized error message and open settings action', (
    tester,
  ) async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    final device = _FakeDeviceController();
    final overlay = OverlayController(bridge: nativeBridge);
    final post = _ToolbarPostProcessingController();
    final uiState = HomeUiState()
      ..setError(NativeErrorCode.screenRecordingPermission);
    String? openedPane;

    addTearDown(recording.dispose);
    addTearDown(device.dispose);
    addTearDown(overlay.dispose);
    addTearDown(post.dispose);
    addTearDown(uiState.dispose);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RecordingController>.value(value: recording),
          ChangeNotifierProvider<DeviceController>.value(value: device),
          ChangeNotifierProvider<OverlayController>.value(value: overlay),
          ChangeNotifierProvider<PostProcessingController>.value(value: post),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HomeToolbar(
              isRecording: false,
              isPaused: false,
              uiState: uiState,
              onExport: () {},
              onOpenSystemSettings: (pane) async {
                openedPane = pane;
              },
              onClearMessage: () {},
            ),
          ),
        ),
      ),
    );

    final l10n = AppLocalizations.of(tester.element(find.byType(HomeToolbar)))!;
    expect(find.text(l10n.errScreenRecordingPermission), findsOneWidget);
    expect(find.text(l10n.openSettings), findsOneWidget);
    expect(find.byKey(const Key('desktop_toolbar_row')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_status_strip')), findsOneWidget);

    await tester.tap(find.text(l10n.openSettings));
    await tester.pump();

    expect(openedPane, 'screen');
  });

  testWidgets('explicit ui notice dismiss only clears ui notice', (
    tester,
  ) async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    final device = _FakeDeviceController()
      ..setTestError(NativeErrorCode.screenRecordingPermission);
    final overlay = OverlayController(bridge: nativeBridge);
    final post = _ToolbarPostProcessingController();
    final uiState = HomeUiState()
      ..setNotice(
        const HomeUiNotice(
          message: 'Export complete',
          tone: HomeUiNoticeTone.success,
        ),
      );

    addTearDown(recording.dispose);
    addTearDown(device.dispose);
    addTearDown(overlay.dispose);
    addTearDown(post.dispose);
    addTearDown(uiState.dispose);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RecordingController>.value(value: recording),
          ChangeNotifierProvider<DeviceController>.value(value: device),
          ChangeNotifierProvider<OverlayController>.value(value: overlay),
          ChangeNotifierProvider<PostProcessingController>.value(value: post),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HomeToolbar(
              isRecording: false,
              isPaused: false,
              uiState: uiState,
              onExport: () {},
              onOpenSystemSettings: (_) async {},
              onClearMessage: () {
                uiState.clearError();
                device.setTestError(null);
              },
            ),
          ),
        ),
      ),
    );

    final l10n = AppLocalizations.of(tester.element(find.byType(HomeToolbar)))!;

    expect(find.byKey(const Key('toolbar_notice_lane')), findsOneWidget);
    expect(find.text('Export complete'), findsOneWidget);
    expect(find.text(l10n.errScreenRecordingPermission), findsNothing);

    final dismissFinder = find.descendant(
      of: find.byKey(const Key('toolbar_notice_lane')),
      matching: find.byType(MacosIconButton),
    );
    tester.widget<MacosIconButton>(dismissFinder).onPressed!.call();
    await tester.pumpAndSettle();

    expect(find.text('Export complete'), findsNothing);
    expect(find.text(l10n.errScreenRecordingPermission), findsOneWidget);
    expect(find.byKey(const Key('toolbar_status_strip')), findsOneWidget);
  });

  testWidgets(
    'blank recording start errors fall back to the localized window unavailable message',
    (tester) async {
      final nativeBridge = NativeBridge.instance;
      final settings = SettingsController(nativeBridge: nativeBridge);
      final recording = RecordingController(
        nativeBridge: nativeBridge,
        settings: settings,
      );
      final device = _FakeDeviceController();
      final overlay = OverlayController(bridge: nativeBridge);
      final post = _ToolbarPostProcessingController();
      final uiState = HomeUiState();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      addTearDown(recording.dispose);
      addTearDown(device.dispose);
      addTearDown(overlay.dispose);
      addTearDown(post.dispose);
      addTearDown(uiState.dispose);
      addTearDown(settings.dispose);

      messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
        switch (call.method) {
          case 'startRecording':
            throw PlatformException(
              code: NativeErrorCode.windowNotAvailable,
              message: '',
            );
          case 'getPermissionStatus':
            return <String, bool>{
              'screenRecording': true,
              'microphone': false,
              'camera': false,
              'accessibility': false,
            };
          case 'getAudioSources':
          case 'getVideoSources':
          case 'getDisplays':
          case 'getAppWindows':
            return <dynamic>[];
          case 'getStorageSnapshot':
            return <String, dynamic>{
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
          case 'stopRecording':
          case 'pauseRecording':
          case 'resumeRecording':
          case 'togglePauseRecording':
          case 'requestScreenRecordingPermission':
          case 'requestMicrophonePermission':
          case 'requestCameraPermission':
          case 'openAccessibilitySettings':
          case 'openScreenRecordingSettings':
          case 'openSystemSettings':
          case 'revealRecordingsFolder':
          case 'revealTempFolder':
          case 'clearCachedRecordings':
          case 'setAudioMix':
          case 'previewOpen':
          case 'previewClose':
          case 'previewPlay':
          case 'previewPause':
          case 'previewSeekTo':
          case 'previewPeekTo':
          case 'inlinePreviewStop':
          case 'checkForUpdates':
            return null;
          case 'getRecordingCapabilities':
            return <String, dynamic>{
              'canPauseResume': true,
              'backend': 'avfoundation',
              'strategy': 'av_file_output',
            };
          case 'getExcludeRecorderApp':
            return false;
          case 'getExcludeMicFromSystemAudio':
            return true;
          default:
            return null;
        }
      });

      recording.beginRecordingStartIntent();
      await recording.startRecording();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RecordingController>.value(value: recording),
            ChangeNotifierProvider<DeviceController>.value(value: device),
            ChangeNotifierProvider<OverlayController>.value(value: overlay),
            ChangeNotifierProvider<PostProcessingController>.value(value: post),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: HomeToolbar(
                isRecording: false,
                isPaused: false,
                uiState: uiState,
                onExport: () {},
                onOpenSystemSettings: (_) async {},
                onClearMessage: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(HomeToolbar)),
      )!;
      expect(recording.errorCode, NativeErrorCode.windowNotAvailable);
      expect(recording.errorMessage, NativeErrorCode.windowNotAvailable);
      expect(find.text(l10n.errWindowUnavailable), findsOneWidget);
    },
  );

  testWidgets('background export renders in separate export lane', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DesktopToolbar(
            isRecording: false,
            isPaused: false,
            exportStatus: const ToolbarExportStatusPresentation(
              progress: 0.42,
              cancelRequested: false,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('desktop_toolbar_row')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_status_strip')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_export_lane')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_notice_lane')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('desktop_toolbar_row')),
        matching: find.textContaining('42%'),
      ),
      findsNothing,
    );
  });
}
