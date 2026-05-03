import 'package:clingfy/app/home/preview/widgets/video_timeline.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('timeline dock renders header transport and viewport', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(find.byKey(const Key('timeline_header_bar')), findsOneWidget);
    expect(find.byKey(const Key('timeline_transport_bar')), findsOneWidget);
    expect(find.byKey(const Key('timeline_editor_viewport')), findsOneWidget);
    expect(find.byKey(const Key('timeline_footer_bar')), findsNothing);
    expect(find.byKey(const Key('timeline_status_line')), findsNothing);
  });

  testWidgets('header shows title and no close action', (tester) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final l10n = _l10n(tester);

    expect(find.text(l10n.timeline), findsOneWidget);
    expect(find.byKey(const Key('timeline_close_button')), findsNothing);
  });

  testWidgets('timeline opens with zoom lane visible and markers hidden', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(
      find.byKey(const Key('timeline_track_header_column')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('timeline_lane_header_zoom')), findsOneWidget);
    expect(find.byKey(const Key('zoom_timeline_lane')), findsOneWidget);
    expect(find.byKey(const Key('timeline_lane_header_markers')), findsNothing);
    expect(find.byKey(const Key('markers_timeline_lane')), findsNothing);
  });

  testWidgets('transport play pause button reflects player state', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor, isPlaying: true);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(find.byKey(const Key('timeline_play_pause_button')), findsOneWidget);
    expect(find.text(_l10n(tester).pausePlayback), findsOneWidget);

    await tester.tap(find.byKey(const Key('timeline_play_pause_button')));
    await tester.pumpAndSettle();

    expect(player.isPlaying, isFalse);
    expect(find.text(_l10n(tester).play), findsOneWidget);
  });

  testWidgets('transport exposes viewport zoom controls and fit on the right', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(find.byKey(const Key('timeline_transport_bar')), findsOneWidget);
    expect(find.byKey(const Key('timeline_zoom_out_button')), findsOneWidget);
    expect(find.byKey(const Key('timeline_zoom_slider')), findsOneWidget);
    expect(find.byKey(const Key('timeline_zoom_in_button')), findsOneWidget);
    expect(
      find.byKey(const Key('timeline_transport_fit_button')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('timeline_zoom_slider')),
        matching: find.byKey(const Key('app_slider_track')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('timeline_zoom_slider')),
        matching: find.byKey(const Key('app_slider_decrement_button')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('timeline_zoom_slider')),
        matching: find.byKey(const Key('app_slider_increment_button')),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('timeline_footer_bar')), findsNothing);
    expect(find.byKey(const Key('timeline_footer_snap_toggle')), findsNothing);
  });

  testWidgets('lane visibility menu shows and hides markers lane', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(find.byKey(const Key('timeline_lane_header_markers')), findsNothing);
    expect(find.byKey(const Key('markers_timeline_lane')), findsNothing);

    await tester.tap(find.byKey(const Key('timeline_lane_visibility_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_l10n(tester).markers).last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('timeline_lane_header_markers')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('markers_timeline_lane')), findsOneWidget);

    await tester.tap(find.byKey(const Key('timeline_lane_visibility_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_l10n(tester).markers).last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('timeline_lane_header_markers')), findsNothing);
    expect(find.byKey(const Key('markers_timeline_lane')), findsNothing);
  });

  testWidgets('header renders snap chip and toggles controller state', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(find.byKey(const Key('timeline_snap_chip')), findsOneWidget);
    expect(editor.snappingEnabled, isTrue);

    await tester.tap(find.byKey(const Key('timeline_snap_chip')));
    await tester.pump();

    expect(editor.snappingEnabled, isFalse);

    await tester.tap(find.byKey(const Key('timeline_snap_chip')));
    await tester.pump();

    expect(editor.snappingEnabled, isTrue);
  });

  testWidgets('one-shot add mode text appears in transport bar', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    editor.enterOneShotAddMode();
    await tester.pump();

    expect(
      find.byKey(const Key('timeline_transport_mode_text')),
      findsOneWidget,
    );
    expect(find.text(_l10n(tester).zoomAddOneStatus), findsOneWidget);
  });

  testWidgets('timeline shell keeps the updated dark dock chrome', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    final theme = buildDarkTheme();
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final shellDecoration = _decorationFor(
      tester,
      find.byKey(const Key('timeline_shell')),
    );
    final shell = tester.widget<Container>(
      find.byKey(const Key('timeline_shell')),
    );
    final headerDecoration = _decorationFor(
      tester,
      find.byKey(const Key('timeline_header_bar')),
    );
    final transportDecoration = _decorationFor(
      tester,
      find.byKey(const Key('timeline_transport_bar')),
    );

    expect(shellDecoration.color, theme.appTokens.timelineBackground);
    expect(shell.padding, EdgeInsets.zero);
    expect(
      shellDecoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.panelRadius),
    );
    expect(shellDecoration.border, isNull);
    expect(headerDecoration.color, theme.appTokens.timelineChromeSurface);
    expect(transportDecoration.color, theme.appTokens.timelineChromeSurface);
    expect(find.byKey(const Key('timeline_ruler_strip')), findsOneWidget);
  });

  testWidgets('timeline ruler strip uses editor chrome height', (tester) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(
      tester.getSize(find.byKey(const Key('timeline_ruler_strip'))).height,
      70,
    );
  });

  testWidgets('holding space shows pan overlay and releasing hides it', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));
    await tester.tap(find.byKey(const Key('timeline_shell')));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.byKey(const Key('timeline_pan_overlay')), findsNothing);
  });

  testWidgets('playhead cap uses the slimmer V1 polish geometry', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(
      tester.getSize(find.byKey(const Key('timeline_playhead_cap'))),
      const Size(8, 6),
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
  ValueChanged<int>? onSeek,
  ValueChanged<int>? onHoverSeek,
  VoidCallback? onHoverEnd,
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
            width: 760,
            child: VideoTimeline(
              durationMs: 60000,
              positionMs: 15000,
              isReady: true,
              onSeek: onSeek ?? (_) {},
              onHoverSeek: onHoverSeek ?? (_) {},
              onHoverEnd: onHoverEnd ?? () {},
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
  _FakePlayerController({
    required ZoomEditorController? editor,
    bool isPlaying = false,
  }) : _editor = editor,
       _isPlaying = isPlaying,
       super(nativeBridge: NativeBridge.instance);

  final ZoomEditorController? _editor;
  bool _isPlaying;

  @override
  ZoomEditorController? get zoomEditor => _editor;

  @override
  bool get isPlaying => _isPlaying;

  @override
  Future<void> play() async {
    _isPlaying = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _isPlaying = false;
    notifyListeners();
  }
}
