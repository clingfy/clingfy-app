import 'package:clingfy/app/home/preview/widgets/video_timeline.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  testWidgets('toolbar shows title, time, and close icon control', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    var didClose = false;
    await tester.pumpWidget(
      _buildTimeline(player: player, onClose: () => didClose = true),
    );

    final l10n = _l10n(tester);

    expect(find.text(l10n.timeline), findsOneWidget);
    expect(find.text('00:15 / 01:00'), findsOneWidget);
    expect(find.byKey(const Key('timeline_close_button')), findsOneWidget);
    expect(find.text(l10n.close), findsNothing);

    await tester.tap(find.byKey(const Key('timeline_close_button')));
    await tester.pump();

    expect(didClose, isTrue);
  });

  testWidgets('add controls and selection controls are grouped separately', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 100, 'endMs': 200, 'source': 'auto'},
      ],
    );
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final addGroup = find.byKey(const Key('timeline_toolbar_add_group'));
    final selectionGroup = find.byKey(
      const Key('timeline_toolbar_selection_group'),
    );

    expect(addGroup, findsOneWidget);
    expect(selectionGroup, findsOneWidget);
    expect(
      tester.getTopLeft(selectionGroup).dx,
      greaterThan(tester.getTopLeft(addGroup).dx),
    );
  });

  testWidgets('one-shot add status line appears when add mode is enabled', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    editor.enterOneShotAddMode();
    await tester.pump();

    final l10n = _l10n(tester);
    expect(find.byKey(const Key('timeline_status_line')), findsOneWidget);
    expect(find.text(l10n.zoomAddOneStatus), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('timeline_mode_chip')),
        matching: find.text(l10n.zoomAddOne),
      ),
      findsOneWidget,
    );
  });

  testWidgets('sticky add status line appears when pin toggle is enabled', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    editor.enterStickyAddMode();
    await tester.pump();

    final l10n = _l10n(tester);
    expect(find.byKey(const Key('timeline_status_line')), findsOneWidget);
    expect(find.text(l10n.zoomKeepAddingStatus), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('timeline_mode_chip')),
        matching: find.text(l10n.zoomKeepAdding),
      ),
      findsOneWidget,
    );
  });

  testWidgets('sticky add feedback is distinct from one-shot add', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final l10n = _l10n(tester);

    editor.enterOneShotAddMode();
    await tester.pump();
    expect(find.text(l10n.zoomAddOneStatus), findsOneWidget);

    editor.enterStickyAddMode();
    await tester.pump();
    expect(find.text(l10n.zoomAddOneStatus), findsNothing);
    expect(find.text(l10n.zoomKeepAddingStatus), findsOneWidget);
  });

  testWidgets('selection badge shows the correct count', (tester) async {
    final editor = await _createEditor(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 100, 'endMs': 220, 'source': 'auto'},
        {'id': 'auto_1', 'startMs': 340, 'endMs': 500, 'source': 'auto'},
      ],
    );
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    editor.selectAllVisible();
    await tester.pump();

    expect(find.text(_l10n(tester).zoomSelectedCount(2)), findsOneWidget);
  });

  testWidgets('dark timeline uses unified shell and time chip chrome', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);
    final theme = buildDarkTheme();

    await tester.pumpWidget(_buildTimeline(player: player));

    final shellDecoration = _decorationFor(
      tester,
      find.byKey(const Key('timeline_shell')),
    );
    final timeChipDecoration = _decorationFor(
      tester,
      find.byKey(const Key('timeline_time_chip')),
    );
    final rulerBand = find.byKey(const Key('timeline_ruler_band'));

    expect(shellDecoration.color, theme.appTokens.timelineBackground);
    expect(
      shellDecoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.panelRadius),
    );
    expect(shellDecoration.border, isNull);
    expect(
      tester.getSize(rulerBand).height,
      theme.appEditorChrome.timelineRulerHeight,
    );
    expect(timeChipDecoration.color, theme.inputDecorationTheme.fillColor);
    expect(
      timeChipDecoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.pillRadius),
    );
    expect(find.byKey(const Key('zoom_track_shell')), findsOneWidget);
  });

  testWidgets('timeline ruler band uses the taller editor height', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(
      tester.getSize(find.byKey(const Key('timeline_ruler_band'))).height,
      70,
    );
  });
}

Future<ZoomEditorController> _createEditor(
  WidgetTester tester, {
  List<Map<String, Object?>> autoSegments = const [],
  List<Map<String, Object?>> manualSegments = const [],
}) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
    switch (call.method) {
      case 'getZoomSegments':
        return autoSegments;
      case 'getManualZoomSegments':
        return manualSegments;
      case 'saveManualZoomSegments':
        return true;
      case 'previewSetZoomSegments':
        return null;
      default:
        return null;
    }
  });

  final controller = ZoomEditorController(
    nativeBridge: NativeBridge.instance,
    videoPath: '/tmp/timeline.mov',
    durationMs: 60000,
  );
  await controller.init();
  addTearDown(controller.dispose);
  return controller;
}

Widget _buildTimeline({
  required PlayerController player,
  VoidCallback? onClose,
}) {
  return ChangeNotifierProvider<PlayerController>.value(
    value: player,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 920,
            child: VideoTimeline(
              durationMs: 60000,
              positionMs: 15000,
              isReady: true,
              onSeek: (_) {},
              onClose: onClose ?? () {},
              onHoverSeek: (_) {},
              onHoverEnd: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

AppLocalizations _l10n(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(VideoTimeline)))!;
}

BoxDecoration _decorationFor(WidgetTester tester, Finder finder) {
  final container = tester.widget<Container>(finder);
  return container.decoration! as BoxDecoration;
}

class _FakePlayerController extends PlayerController {
  _FakePlayerController({required ZoomEditorController? editor})
    : _editor = editor,
      super(nativeBridge: NativeBridge.instance);

  final ZoomEditorController? _editor;

  @override
  ZoomEditorController? get zoomEditor => _editor;
}
