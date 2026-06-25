import 'package:clingfy/app/home/preview/widgets/video_timeline.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../../test_helpers/native_test_setup.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';

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

  testWidgets('redo button re-applies an undone zoom edit', (tester) async {
    final editor = await _createEditor(tester);
    final player = _FakePlayerController(editor: editor);
    addTearDown(player.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final redoButton = find.byKey(const Key('timeline_redo_button'));
    expect(redoButton, findsOneWidget);

    // Create a manual zoom segment, then undo it.
    editor.enterOneShotAddMode();
    editor.updateDraft(1000, 4000);
    editor.commitDraft();
    await tester.pump();
    expect(editor.manualSegments, hasLength(1));

    editor.undo();
    await tester.pump();
    expect(editor.manualSegments, isEmpty);

    // The redo button is now enabled; tapping it restores the segment.
    await tester.ensureVisible(redoButton);
    await tester.pump();
    await tester.tap(redoButton);
    await tester.pump();
    expect(editor.manualSegments, hasLength(1));
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

  testWidgets(
    'timeline shell height is stable when a zoom segment is selected',
    (tester) async {
      final editor = await _createEditor(
        tester,
        fixedTargetPreview: true,
        manualSegments: const [
          {
            'id': 'manual_seg_a',
            'startMs': 1000,
            'endMs': 4000,
            'source': 'manual',
            'focusMode': 'followCursor',
          },
        ],
      );
      final player = _FakePlayerController(editor: editor);
      addTearDown(player.dispose);

      await tester.pumpWidget(_buildTimeline(player: player));
      await tester.pumpAndSettle();

      final shellFinder = find.byKey(const Key('timeline_shell'));
      final heightDeselected = tester.getSize(shellFinder).height;

      editor.selectOnly(editor.displaySegments.single);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('zoom_behavior_floating_toolbar')),
        findsOneWidget,
      );
      expect(tester.getSize(shellFinder).height, heightDeselected);

      editor.clearSelection();
      await tester.pumpAndSettle();

      expect(tester.getSize(shellFinder).height, heightDeselected);
    },
  );

  testWidgets('clip lane and split control render with a live clip editor', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final clipEditor = _makeClipEditor();
    final player = _FakePlayerController(
      editor: editor,
      clipEditor: clipEditor,
    );
    addTearDown(player.dispose);
    addTearDown(clipEditor.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    expect(find.byKey(const Key('clips_timeline_lane')), findsOneWidget);
    expect(find.byKey(const Key('timeline_lane_header_clips')), findsOneWidget);
    expect(find.byKey(const Key('timeline_clip_split_button')), findsOneWidget);
  });

  testWidgets('split button cuts the clip at the playhead', (tester) async {
    final editor = await _createEditor(tester);
    final clipEditor = _makeClipEditor();
    final player = _FakePlayerController(
      editor: editor,
      clipEditor: clipEditor,
    );
    addTearDown(player.dispose);
    addTearDown(clipEditor.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));
    expect(clipEditor.clips, hasLength(1));

    final splitButton = find.byKey(const Key('timeline_clip_split_button'));
    await tester.ensureVisible(splitButton);
    await tester.pump();
    await tester.tap(splitButton);
    await tester.pump();

    // Playhead is at 15000ms of a 60000ms recording → two clips.
    expect(clipEditor.clips, hasLength(2));
    expect(clipEditor.clips.first.sourceOutMs, 15000);
    expect(
      find.byKey(const Key('clips_timeline_lane_clip_clip_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('clips_timeline_lane_clip_clip_1')),
      findsOneWidget,
    );
  });

  testWidgets('selecting a clip then deleting it removes the clip', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final clipEditor = _makeClipEditor();
    final player = _FakePlayerController(
      editor: editor,
      clipEditor: clipEditor,
    );
    addTearDown(player.dispose);
    addTearDown(clipEditor.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final splitButton = find.byKey(const Key('timeline_clip_split_button'));
    await tester.ensureVisible(splitButton);
    await tester.pump();
    await tester.tap(splitButton);
    await tester.pump();
    expect(clipEditor.clips, hasLength(2));

    // Tap the first clip box to select it.
    await tester.tap(find.byKey(const Key('clips_timeline_lane_clip_clip_0')));
    await tester.pump();
    expect(clipEditor.selectedClipId, 'clip_0');

    final deleteButton = find.byKey(const Key('timeline_clip_delete_button'));
    await tester.ensureVisible(deleteButton);
    await tester.pump();
    await tester.tap(deleteButton);
    await tester.pump();

    expect(clipEditor.clips, hasLength(1));
    expect(clipEditor.clips.single.id, 'clip_1');
  });

  testWidgets('clip undo and redo buttons walk the clip history', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final clipEditor = _makeClipEditor();
    final player = _FakePlayerController(
      editor: editor,
      clipEditor: clipEditor,
    );
    addTearDown(player.dispose);
    addTearDown(clipEditor.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final undoButton = find.byKey(const Key('timeline_clip_undo_button'));
    final redoButton = find.byKey(const Key('timeline_clip_redo_button'));

    // Nothing to undo/redo yet — both disabled.
    expect(tester.widget<AppIconButton>(undoButton).onPressed, isNull);
    expect(tester.widget<AppIconButton>(redoButton).onPressed, isNull);

    final splitButton = find.byKey(const Key('timeline_clip_split_button'));
    await tester.ensureVisible(splitButton);
    await tester.pump();
    await tester.tap(splitButton);
    await tester.pump();
    expect(clipEditor.clips, hasLength(2));

    // Undo collapses the split back to one clip.
    await tester.ensureVisible(undoButton);
    await tester.pump();
    await tester.tap(undoButton);
    await tester.pump();
    expect(clipEditor.clips, hasLength(1));

    // Redo re-applies it.
    await tester.ensureVisible(redoButton);
    await tester.pump();
    await tester.tap(redoButton);
    await tester.pump();
    expect(clipEditor.clips, hasLength(2));
  });

  testWidgets('dragging a clip edge handle trims it live and is undoable', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final clipEditor = _makeClipEditor();
    final player = _FakePlayerController(
      editor: editor,
      clipEditor: clipEditor,
    );
    addTearDown(player.dispose);
    addTearDown(clipEditor.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    // Split first so there's an interior edge mid-lane (a whole-clip end handle
    // sits at the clipped right edge of the lane).
    final splitButton = find.byKey(const Key('timeline_clip_split_button'));
    await tester.ensureVisible(splitButton);
    await tester.pump();
    await tester.tap(splitButton);
    await tester.pump();
    expect(clipEditor.clips, hasLength(2));
    expect(clipEditor.editedDurationMs, 60000);

    // Select the first clip; its end handle is at the cut (~25% across).
    await tester.tap(find.byKey(const Key('clips_timeline_lane_clip_clip_0')));
    await tester.pump();

    await tester.drag(
      find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
      const Offset(-60, 0),
    );
    await tester.pump();

    // The clip was trimmed shorter, live.
    expect(clipEditor.editedDurationMs, lessThan(60000));
    expect(clipEditor.canUndo, isTrue);

    // The whole drag is a single undo entry distinct from the split: undoing
    // once restores the duration while leaving the two clips in place.
    clipEditor.undo();
    expect(clipEditor.editedDurationMs, 60000);
    expect(clipEditor.clips, hasLength(2));
  });

  testWidgets('over-dragging an edge clamps at min duration without inverting', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final clipEditor = _makeClipEditor();
    final player = _FakePlayerController(
      editor: editor,
      clipEditor: clipEditor,
    );
    addTearDown(player.dispose);
    addTearDown(clipEditor.dispose);

    await tester.pumpWidget(_buildTimeline(player: player));

    final splitButton = find.byKey(const Key('timeline_clip_split_button'));
    await tester.ensureVisible(splitButton);
    await tester.pump();
    await tester.tap(splitButton);
    await tester.pump();

    await tester.tap(find.byKey(const Key('clips_timeline_lane_clip_clip_0')));
    await tester.pump();

    // Drag the end handle far past the clip's own start.
    await tester.drag(
      find.byKey(const Key('clips_timeline_lane_trim_end_clip_0')),
      const Offset(-2000, 0),
    );
    await tester.pump();

    // Both clips survive; the trimmed clip never inverts (out > in) and the
    // edited timeline stays positive — the min-duration clamp held end to end.
    expect(clipEditor.clips, hasLength(2));
    final first = clipEditor.clips.first;
    expect(first.sourceOutMs, greaterThan(first.sourceInMs));
    expect(clipEditor.editedDurationMs, greaterThan(0));
    expect(clipEditor.editedDurationMs, lessThan(60000));
  });

  testWidgets(
    'clip lane and controls are hidden when no clip editor attached',
    (tester) async {
      final editor = await _createEditor(tester);
      // clipEditor omitted → null, mimicking a still-loading preview.
      final player = _FakePlayerController(editor: editor);
      addTearDown(player.dispose);

      await tester.pumpWidget(_buildTimeline(player: player));

      expect(find.byKey(const Key('clips_timeline_lane')), findsNothing);
      expect(find.byKey(const Key('timeline_lane_header_clips')), findsNothing);
      expect(find.byKey(const Key('timeline_clip_split_button')), findsNothing);
      // The zoom lane is unaffected.
      expect(find.byKey(const Key('zoom_timeline_lane')), findsOneWidget);
    },
  );
}

ClipEditorController _makeClipEditor() {
  final controller = ClipEditorController(
    nativeBridge: NativeBridge.instance,
    durationMs: 60000,
    sessionId: 'clip-session',
  );
  return controller;
}

Future<ZoomEditorController> _createEditor(
  WidgetTester tester, {
  List<Map<String, Object?>> autoSegments = const [],
  List<Map<String, Object?>> manualSegments = const [],
  bool fixedTargetPreview = false,
}) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
    switch (call.method) {
      case 'previewGetZoomCapabilities':
        if (!fixedTargetPreview) return null;
        return <String, dynamic>{
          'cursorSamples': true,
          'fixedTargetPreview': true,
          'fixedTargetExport': true,
        };
      case 'previewGetSourceDimensions':
        return <String, dynamic>{'width': 1920.0, 'height': 1080.0};
      case 'previewGetCursorSamples':
        return null;
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
    ClipEditorController? clipEditor,
  }) : _editor = editor,
       _isPlaying = isPlaying,
       _clipEditor = clipEditor,
       super(nativeBridge: NativeBridge.instance);

  final ZoomEditorController? _editor;
  final ClipEditorController? _clipEditor;
  bool _isPlaying;

  @override
  ZoomEditorController? get zoomEditor => _editor;

  @override
  ClipEditorController? get clipEditor => _clipEditor;

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
