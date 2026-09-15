import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/widgets/post_processing_sidebar_container.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_audio_section.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

import '../../../test_helpers/native_test_setup.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';

class _Harness {
  _Harness({
    required this.settings,
    required this.recording,
    required this.device,
    required this.player,
    required this.post,
  });

  final SettingsController settings;
  final RecordingController recording;
  final DeviceController device;
  final PlayerController player;
  final PostProcessingController post;

  void dispose() {
    post.dispose();
    player.dispose();
    settings.dispose();
  }
}

class _FakeRecordingController extends Fake implements RecordingController {
  @override
  bool get canInteractWithPreview => true;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}

class _FakeDeviceController extends Fake implements DeviceController {
  @override
  String get selectedAudioSourceId => DeviceController.noAudioId;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}

void main() {
  // Phase 10.3 forked this surface's widget tree by platform (no-op
  // controls hidden / zoom editing disabled on Windows). These legacy
  // assertions pin the macOS branch regardless of the host OS; Windows
  // branches are covered by dedicated 10.3 tests.
  setUp(() {
    debugPlatformKindOverride = PlatformKind.macos;
  });
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  Future<_Harness> createHarness() async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();

    final recording = _FakeRecordingController();
    final device = _FakeDeviceController();
    final player = PlayerController(nativeBridge: nativeBridge);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    return _Harness(
      settings: settings,
      recording: recording,
      device: device,
      player: player,
      post: post,
    );
  }

  Widget buildTestApp(_Harness harness, {int selectedIndex = 0}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<RecordingController>.value(
          value: harness.recording,
        ),
        ChangeNotifierProvider<DeviceController>.value(value: harness.device),
        ChangeNotifierProvider<PostProcessingController>.value(
          value: harness.post,
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: MacosTheme(
          data: buildMacosTheme(Brightness.dark),
          child: Scaffold(
            body: PostProcessingSidebarContainer(
              settingsController: harness.settings,
              isRecording: false,
              selectedIndex: selectedIndex,
              availableWidth: 360,
              isCompact: false,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'container rebuilds canvas aspect selection when post settings change',
    (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      final harness = await createHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(buildTestApp(harness));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final autoFinder = find.byKey(
        const ValueKey('canvas_aspect_option_auto'),
      );
      final wideFinder = find.byKey(
        const ValueKey('canvas_aspect_option_youtube169'),
      );

      expect(
        tester.getSemantics(autoFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );
      expect(
        tester.getSemantics(wideFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isFalse,
      );

      harness.settings.post.updateLayoutPreset(LayoutPreset.youtube169);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        tester.getSemantics(autoFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isFalse,
      );
      expect(
        tester.getSemantics(wideFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );

      semanticsHandle.dispose();
    },
  );

  testWidgets('scene-derived audio verdict overrides the device gate '
      '(audio separation D10)', (tester) async {
    // The recording HAS system audio but NO mic track (separated,
    // mic-less). The fake device reports noAudioId — under the legacy
    // device gate everything would be disabled, so enabled volume here
    // proves the scene verdict wins; disabled gain + the notice prove
    // the mic-only gating.
    await clearCommonNativeMocks();
    await installCommonNativeMocks(
      recordingSceneInfoReply: <String, Object?>{
        'projectPath': '/tmp/p.clingfyproj',
        'screenPath': '/tmp/p.clingfyproj/capture/screen.mov',
        'hasMicAudio': false,
        'hasSystemAudio': true,
        'micGainApplies': false,
      },
    );
    final harness = await createHarness();
    addTearDown(harness.dispose);

    harness.post.attachToRecording(
      sessionId: 'sess-audio-gate',
      projectPath: '/tmp/p.clingfyproj',
    );
    // selectedIndex 3 = Export tab, where PostAudioSection lives.
    await tester.pumpWidget(buildTestApp(harness, selectedIndex: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(harness.post.sceneHasAudio, isTrue);
    expect(harness.post.sceneMicGainApplies, isFalse);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final audioSection = find.byType(PostAudioSection);
    expect(audioSection, findsOneWidget);
    final sliders = tester
        .widgetList<AppSlider>(
          find.descendant(of: audioSection, matching: find.byType(AppSlider)),
        )
        .toList();
    // PostAudioSection order: volume first, gain second.
    expect(sliders, hasLength(2));
    expect(
      sliders[0].onChanged,
      isNotNull,
      reason:
          'system audio exists — volume must be live even though '
          'the DEVICE selection says no audio',
    );
    expect(
      sliders[1].onChanged,
      isNull,
      reason:
          'gain is mic-only on a separated recording — a mic-less '
          'one must not offer a slider the pipeline ignores',
    );
    expect(find.text(l10n.noMicAudioFound), findsOneWidget);
  });

  testWidgets('absent scene audio keys keep the legacy device gate', (
    tester,
  ) async {
    // macOS-shaped reply (no audio keys): the device fake says noAudioId,
    // so both sliders stay disabled — exactly the pre-separation gate.
    await clearCommonNativeMocks();
    await installCommonNativeMocks(
      recordingSceneInfoReply: <String, Object?>{
        'projectPath': '/tmp/p.clingfyproj',
        'screenPath': '/tmp/p.clingfyproj/capture/screen.mov',
      },
    );
    final harness = await createHarness();
    addTearDown(harness.dispose);

    harness.post.attachToRecording(
      sessionId: 'sess-legacy-gate',
      projectPath: '/tmp/p.clingfyproj',
    );
    await tester.pumpWidget(buildTestApp(harness, selectedIndex: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(harness.post.sceneHasAudio, isNull);

    final sliders = tester
        .widgetList<AppSlider>(
          find.descendant(
            of: find.byType(PostAudioSection),
            matching: find.byType(AppSlider),
          ),
        )
        .toList();
    expect(sliders, hasLength(2));
    expect(sliders[0].onChanged, isNull);
    expect(sliders[1].onChanged, isNull);
  });

  testWidgets('detaching the recording clears the scene audio verdict', (
    tester,
  ) async {
    await clearCommonNativeMocks();
    await installCommonNativeMocks(
      recordingSceneInfoReply: <String, Object?>{
        'projectPath': '/tmp/p.clingfyproj',
        'screenPath': '/tmp/p.clingfyproj/capture/screen.mov',
        'hasMicAudio': true,
        'hasSystemAudio': true,
        'micGainApplies': true,
      },
    );
    final harness = await createHarness();
    addTearDown(harness.dispose);

    harness.post.attachToRecording(
      sessionId: 'sess-reset',
      projectPath: '/tmp/p.clingfyproj',
    );
    // Let the async scene-info load land.
    await tester.pumpWidget(buildTestApp(harness, selectedIndex: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(harness.post.sceneHasAudio, isTrue);
    expect(harness.post.sceneMicGainApplies, isTrue);

    // A stale verdict must never leak into the next recording.
    harness.post.detachRecording();
    expect(harness.post.sceneHasAudio, isNull);
    expect(harness.post.sceneMicGainApplies, isNull);
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('the captions Stop button stays pressable while a transcription '
      'runs', (tester) async {
    // The regression this pins: `isEditingLocked` grew a captions term, the
    // container feeds it to an IgnorePointer over the WHOLE sidebar, and the
    // Stop button lives inside that subtree — its only call site in the app.
    // Generate, and the 626 MB model download could no longer be stopped.
    await clearCommonNativeMocks();
    await installCommonNativeMocks();

    final calls = <MethodCall>[];
    // Held open so the transcription can be observed mid-flight, which is the
    // only moment the Stop button exists at all.
    final gate = Completer<List<Map<String, Object?>>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'captionsCapability':
          return {
            'available': true,
            'hasMicAudio': true,
            'hasSystemAudio': true,
          };
        case 'generateCaptions':
          return gate.future;
        default:
          return null;
      }
    });

    final harness = await createHarness();
    addTearDown(harness.dispose);
    harness.post.attachToRecording(
      sessionId: 'sess-captions-stop',
      projectPath: '/tmp/p.clingfyproj',
    );

    // selectedIndex 3 = Export tab, where PostCaptionsSection lives.
    await tester.pumpWidget(buildTestApp(harness, selectedIndex: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final run = harness.post.generateCaptions();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(harness.post.isGeneratingCaptions, isTrue);

    final stop = find.byKey(const Key('captions_cancel_button'));
    expect(stop, findsOneWidget, reason: 'the progress row is up');
    expect(
      stop.hitTestable(),
      findsOneWidget,
      reason: 'an IgnorePointer over the sidebar takes it out of the hit test',
    );

    await tester.tap(stop);
    await tester.pump();

    expect(
      calls.where((c) => c.method == 'cancelCaptions'),
      hasLength(1),
      reason: 'the press has to actually reach the engine, not just render',
    );
    expect(harness.post.isCancellingCaptions, isTrue);

    gate.complete(const []);
    await run;
    await tester.pump();
  });

  testWidgets('the newly-opened recording gets a dead Generate button with a '
      'reason on it', (tester) async {
    // End to end through the seam the controller state has to cross: opening
    // another recording cancels the transcription, but the cancel is
    // best-effort against a download that cannot be interrupted, so the engine
    // stays occupied. Recording B rendered a live "Generate subtitles" for that
    // whole window and every press was silently dropped.
    await clearCommonNativeMocks();
    await installCommonNativeMocks();

    // Held open so the engine can be observed still occupied after the switch.
    final gate = Completer<List<Map<String, Object?>>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'captionsCapability':
          return {
            'available': true,
            'hasMicAudio': true,
            'hasSystemAudio': true,
          };
        case 'generateCaptions':
          return gate.future;
        default:
          return null;
      }
    });

    final harness = await createHarness();
    addTearDown(harness.dispose);
    harness.post.attachToRecording(
      sessionId: 'sess-a',
      projectPath: '/tmp/a.clingfyproj',
    );

    // selectedIndex 3 = Export tab, where PostCaptionsSection lives.
    await tester.pumpWidget(buildTestApp(harness, selectedIndex: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final run = harness.post.generateCaptions();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    harness.post.attachToRecording(
      sessionId: 'sess-b',
      projectPath: '/tmp/b.clingfyproj',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final generate = find.byKey(const Key('captions_generate_button'));
    expect(generate, findsOneWidget, reason: 'B is not the one transcribing');
    expect(
      tester.widget<FilledButton>(generate).onPressed,
      isNull,
      reason: 'the engine is not free; a live button here does nothing at all',
    );
    expect(find.text(l10n.captionsEngineBusy), findsOneWidget);

    gate.complete(const []);
    await run;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      tester.widget<FilledButton>(generate).onPressed,
      isNotNull,
      reason: 'the engine came free, so B can transcribe now',
    );
    expect(find.text(l10n.captionsEngineBusy), findsNothing);
  });

  testWidgets('container rebuilds the color sliders when the grade changes '
      '(regression: Selector omitted colorGrade)', (tester) async {
    final semanticsHandle = tester.ensureSemantics();
    final harness = await createHarness();
    addTearDown(harness.dispose);

    // selectedIndex 2 = Effects tab, where PostColorGradeSection lives.
    await tester.pumpWidget(buildTestApp(harness, selectedIndex: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final exposureFinder = find.bySemanticsLabel(l10n.exposure);
    expect(exposureFinder, findsOneWidget);
    expect(tester.getSemantics(exposureFinder).value, '0');

    // Drives the same path the slider's onChanged uses. Before the fix the
    // Selector record omitted colorGrade, so this notify never rebuilt the
    // sidebar and the slider stayed at 0 while the preview moved.
    harness.post.setColorGradeExposure(0.5);
    await tester.pump();
    // Flush the 120ms preview debounce timer so no timers leak.
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.getSemantics(exposureFinder).value, '0.50');

    semanticsHandle.dispose();
  });
}
