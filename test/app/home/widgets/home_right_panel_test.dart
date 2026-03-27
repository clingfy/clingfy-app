import 'dart:async';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/preview/widgets/inline_preview.dart';
import 'package:clingfy/app/home/preview/widgets/inline_preview_panel.dart';
import 'package:clingfy/app/home/preview/widgets/preview_overlay_controls.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/widgets/hero_panel.dart';
import 'package:clingfy/app/home/widgets/home_right_panel.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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

class _TestPostProcessingController extends PostProcessingController {
  _TestPostProcessingController({required this.settings, required this.player})
    : super(settings: settings, player: player, channel: NativeBridge.instance);

  final SettingsController settings;
  final PlayerController player;

  @override
  void dispose() {
    super.dispose();
    player.dispose();
    settings.dispose();
  }
}

class _HostMountCounter {
  int mounts = 0;
}

class _FakePreviewHost extends StatefulWidget {
  const _FakePreviewHost({
    required this.counter,
    required this.onPlatformViewCreated,
  });

  final _HostMountCounter counter;
  final PlatformViewCreatedCallback onPlatformViewCreated;

  @override
  State<_FakePreviewHost> createState() => _FakePreviewHostState();
}

class _FakePreviewHostState extends State<_FakePreviewHost> {
  @override
  void initState() {
    super.initState();
    widget.counter.mounts += 1;
    scheduleMicrotask(() => widget.onPlatformViewCreated(1));
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand(
      child: ColoredBox(
        color: Colors.black,
        child: Center(child: Text('fake-preview-host')),
      ),
    );
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

  Future<
    ({
      RecordingController recording,
      PlayerController player,
      SettingsController settings,
      PostProcessingController post,
    })
  >
  createHarness() async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    final player = PlayerController(nativeBridge: nativeBridge)
      ..bindWorkflow(recording);
    final post = _TestPostProcessingController(
      settings: SettingsController(nativeBridge: nativeBridge),
      player: PlayerController(nativeBridge: nativeBridge),
    );

    return (
      recording: recording,
      player: player,
      settings: settings,
      post: post,
    );
  }

  Widget buildPanel({
    required RecordingController recording,
    required PlayerController player,
    required PostProcessingController post,
    InlinePreviewHostBuilder? previewHostBuilder,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<RecordingController>.value(value: recording),
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<PostProcessingController>.value(value: post),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
          body: Row(
            children: [
              HomeRightPanel(
                isRecording: recording.isRecording,
                isPaused: recording.isPaused,
                isBusy: recording.isBusyTransitioning,
                canPause: recording.canPause,
                canResume: recording.canResume,
                onToggleRecording: () {},
                onPauseRecording: () {},
                onResumeRecording: () {},
                onClosePreview: () {},
                previewHostBuilder: previewHostBuilder,
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('dark idle shell uses framed panel styling', (tester) async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);
    addTearDown(harness.post.dispose);
    final theme = buildDarkTheme();

    await tester.pumpWidget(
      buildPanel(
        recording: harness.recording,
        player: harness.player,
        post: harness.post,
      ),
    );

    final shellDecoration = _decorationFor(
      tester,
      find.byKey(const Key('home_right_panel_shell')),
    );
    final heroDecoration = _decorationFor(
      tester,
      find.byKey(const Key('hero_panel_shell')),
    );

    expect(shellDecoration.color, theme.appTokens.previewPanelBackground);
    expect(
      shellDecoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.panelRadius),
    );
    expect(shellDecoration.border, isNull);
    expect(heroDecoration.color, theme.appTokens.previewPanelBackground);
    expect(
      heroDecoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.panelRadius),
    );
    expect(heroDecoration.border, isNotNull);
  });

  testWidgets('hero body is centered inside the framed shell', (tester) async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);
    addTearDown(harness.post.dispose);

    await tester.pumpWidget(
      buildPanel(
        recording: harness.recording,
        player: harness.player,
        post: harness.post,
      ),
    );

    final heroRect = tester.getRect(find.byKey(const Key('hero_panel_shell')));
    final bodyRect = tester.getRect(find.byKey(const Key('hero_panel_body')));

    expect(bodyRect.center.dx, moreOrLessEquals(heroRect.center.dx));
    expect(bodyRect.center.dy, moreOrLessEquals(heroRect.center.dy));
  });

  testWidgets('recording hero uses a stronger dark recording accent', (
    tester,
  ) async {
    const recordingAccent = Color(0xFFFF4D5D);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: const Scaffold(
          body: HeroPanel(
            isRecording: true,
            isPaused: false,
            isBusy: false,
            canPause: true,
            canResume: false,
            onToggle: _noop,
            onPause: _noop,
            onResume: _noop,
          ),
        ),
      ),
    );

    final recordingIcon = tester.widget<Icon>(find.byIcon(Icons.circle));
    final stopButton = tester.widget<FilledButton>(find.byType(FilledButton));

    expect(recordingIcon.color, recordingAccent);
    expect(stopButton.style?.backgroundColor?.resolve({}), recordingAccent);
  });

  testWidgets('paused hero shows resume and stop actions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: const Scaffold(
          body: HeroPanel(
            isRecording: true,
            isPaused: true,
            isBusy: false,
            canPause: false,
            canResume: true,
            onToggle: _noop,
            onPause: _noop,
            onResume: _noop,
          ),
        ),
      ),
    );

    final l10n = AppLocalizations.of(tester.element(find.byType(HeroPanel)))!;

    expect(find.text(l10n.recordingPaused), findsOneWidget);
    expect(find.text(l10n.resume), findsOneWidget);
    expect(find.text(l10n.stop), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
  });

  testWidgets('keeps hero panel visible through finalizingRecording', (
    tester,
  ) async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);
    addTearDown(harness.post.dispose);

    harness.recording.beginRecordingStartIntent();
    final sessionId = harness.recording.sessionId!;
    await _emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    await harness.recording.stopRecording();

    await tester.pumpWidget(
      buildPanel(
        recording: harness.recording,
        player: harness.player,
        post: harness.post,
      ),
    );

    expect(harness.recording.phase, WorkflowPhase.finalizingRecording);
    expect(find.byType(HeroPanel), findsOneWidget);
    expect(find.byType(InlinePreviewPanel), findsNothing);
  });

  testWidgets('shows preview loading shell before previewReady', (
    tester,
  ) async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);
    addTearDown(harness.post.dispose);

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
      'path': '/tmp/test.mov',
    });

    await tester.pumpWidget(
      buildPanel(
        recording: harness.recording,
        player: harness.player,
        post: harness.post,
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(HomeRightPanel)),
    )!;

    expect(harness.recording.phase, WorkflowPhase.openingPreview);
    expect(find.byType(InlinePreviewPanel), findsOneWidget);
    expect(find.byType(InlinePreview), findsOneWidget);
    expect(find.text(l10n.preparingPreview), findsOneWidget);
    expect(find.byType(PreviewWithOverlayControls), findsOneWidget);
    expect(
      find.byKey(const Key('inline_preview_hidden_cover')),
      findsOneWidget,
    );

    final previewDecoration = _decorationFor(
      tester,
      find.byKey(const Key('inline_preview_frame')),
    );
    final theme = buildDarkTheme();
    expect(previewDecoration.color, theme.appTokens.previewPanelBackground);
    expect(
      previewDecoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.panelRadius),
    );
  });

  testWidgets('shows preview controls only after previewReady', (tester) async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);
    addTearDown(harness.post.dispose);

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
      'path': '/tmp/test.mov',
    });
    await harness.recording.handlePreviewHostMounted();
    await _emitWorkflowEvent({
      'type': 'previewReady',
      'sessionId': sessionId,
      'path': '/tmp/test.mov',
      'token': 'preview_token',
    });

    await tester.pumpWidget(
      buildPanel(
        recording: harness.recording,
        player: harness.player,
        post: harness.post,
      ),
    );

    expect(harness.recording.phase, WorkflowPhase.previewReady);
    expect(find.byType(InlinePreviewPanel), findsOneWidget);
    expect(find.byType(PreviewWithOverlayControls), findsOneWidget);
  });

  testWidgets('preview host is not remounted when preview becomes ready', (
    tester,
  ) async {
    final harness = await createHarness();
    addTearDown(harness.recording.dispose);
    addTearDown(harness.player.dispose);
    addTearDown(harness.settings.dispose);
    addTearDown(harness.post.dispose);

    final counter = _HostMountCounter();
    Widget fakeHost(PlatformViewCreatedCallback onCreated) {
      return _FakePreviewHost(
        counter: counter,
        onPlatformViewCreated: onCreated,
      );
    }

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
      'path': '/tmp/test.mov',
    });

    await tester.pumpWidget(
      buildPanel(
        recording: harness.recording,
        player: harness.player,
        post: harness.post,
        previewHostBuilder: fakeHost,
      ),
    );
    await tester.pump();

    expect(counter.mounts, 1);
    expect(find.byType(HeroPanel), findsNothing);
    expect(find.byType(PreviewWithOverlayControls), findsOneWidget);

    await _emitWorkflowEvent({
      'type': 'previewReady',
      'sessionId': sessionId,
      'path': '/tmp/test.mov',
      'token': 'preview_token',
    });
    await tester.pump();

    expect(counter.mounts, 1);
    expect(find.byType(HeroPanel), findsNothing);
    expect(find.byType(PreviewWithOverlayControls), findsOneWidget);
    expect(find.text('fake-preview-host'), findsOneWidget);
  });
}

void _noop() {}

BoxDecoration _decorationFor(WidgetTester tester, Finder finder) {
  final container = tester.widget<Container>(finder);
  return container.decoration! as BoxDecoration;
}
