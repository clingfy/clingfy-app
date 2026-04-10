import 'package:clingfy/app/home/post_processing/widgets/zoom_track.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  testWidgets('one-shot add drag creates a segment and exits add mode', (
    tester,
  ) async {
    final editor = await _createEditor(tester);

    await tester.pumpWidget(_buildZoomTrack(editor: editor));

    editor.enterOneShotAddMode();
    await tester.pump();

    await _dragAcrossTrack(
      tester,
      find.byType(ZoomTrack),
      startFraction: 0.18,
      endFraction: 0.42,
    );
    await tester.pump();

    expect(editor.addMode, ZoomAddMode.off);
    expect(editor.displaySegments, hasLength(1));
    expect(editor.selectedCount, 1);
  });

  testWidgets('sticky add drag keeps add mode active after commit', (
    tester,
  ) async {
    final editor = await _createEditor(tester);

    await tester.pumpWidget(_buildZoomTrack(editor: editor));

    editor.enterStickyAddMode();
    await tester.pump();

    await _dragAcrossTrack(
      tester,
      find.byType(ZoomTrack),
      startFraction: 0.2,
      endFraction: 0.46,
    );
    await tester.pump();

    expect(editor.addMode, ZoomAddMode.sticky);
    expect(editor.displaySegments, hasLength(1));
    expect(editor.selectedCount, 1);
  });

  testWidgets('double-click quick seek still calls onQuickSeek', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 120, 'endMs': 320, 'source': 'auto'},
      ],
    );

    int? quickSeekMs;
    await tester.pumpWidget(
      _buildZoomTrack(editor: editor, onQuickSeek: (ms) => quickSeekMs = ms),
    );

    final trackRect = tester.getRect(find.byType(ZoomTrack));
    final target = Offset(
      trackRect.left + (trackRect.width * 0.22),
      trackRect.center.dy,
    );

    await _tapAt(tester, target);
    await tester.pump(const Duration(milliseconds: 50));
    await _tapAt(tester, target);
    await tester.pump(const Duration(milliseconds: 120));

    expect(quickSeekMs, 120);
    expect(editor.primarySelectedSegmentId, 'auto_0');
  });

  testWidgets('selection state updates still flow through the track', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 120, 'endMs': 220, 'source': 'auto'},
        {'id': 'auto_1', 'startMs': 320, 'endMs': 430, 'source': 'auto'},
      ],
    );

    await tester.pumpWidget(_buildZoomTrack(editor: editor));

    editor.selectOnly(editor.segmentById('auto_0')!);
    editor.toggleSelection(editor.segmentById('auto_1')!);
    await tester.pump();

    expect(editor.selectedCount, 2);
    expect(
      editor.selectedSegmentIds,
      containsAll(<String>['auto_0', 'auto_1']),
    );
  });

  testWidgets('band selection still selects intersecting segments', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 120, 'endMs': 220, 'source': 'auto'},
        {'id': 'auto_1', 'startMs': 320, 'endMs': 430, 'source': 'auto'},
        {'id': 'auto_2', 'startMs': 720, 'endMs': 820, 'source': 'auto'},
      ],
    );

    await tester.pumpWidget(_buildZoomTrack(editor: editor));

    editor.beginBandSelection(additive: false);
    editor.updateBandSelection(50, 480);
    editor.endBandSelection();
    await tester.pump();

    expect(editor.selectedCount, 2);
    expect(
      editor.selectedSegmentIds,
      containsAll(<String>['auto_0', 'auto_1']),
    );
    expect(editor.selectedSegmentIds, isNot(contains('auto_2')));
  });

  testWidgets('multi-selection still prevents move and trim', (tester) async {
    final editor = await _createEditor(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 120, 'endMs': 260, 'source': 'auto'},
        {'id': 'auto_1', 'startMs': 320, 'endMs': 460, 'source': 'auto'},
      ],
    );

    editor.selectAllVisible();

    await tester.pumpWidget(_buildZoomTrack(editor: editor));

    final original = editor.segmentById('auto_0')!;

    editor.beginMoveAt(170, original);
    editor.beginTrimAt(170, original, TrimHandle.left);
    await tester.pump();

    final afterDrag = editor.segmentById('auto_0')!;
    expect(afterDrag.startMs, original.startMs);
    expect(afterDrag.endMs, original.endMs);
    expect(editor.isMoving, isFalse);
    expect(editor.isTrimming, isFalse);
    expect(editor.selectedCount, 2);
  });

  testWidgets('dark zoom track uses control-fill shell styling', (
    tester,
  ) async {
    final editor = await _createEditor(tester);
    final theme = buildDarkTheme();

    await tester.pumpWidget(_buildZoomTrack(editor: editor));

    final shellFinder = find.byKey(const Key('zoom_track_shell'));
    final shell = tester.widget<Container>(shellFinder);
    final decoration = shell.decoration! as BoxDecoration;

    expect(
      shell.constraints?.maxHeight,
      theme.appEditorChrome.timelineLaneHeight,
    );
    expect(decoration.color, theme.inputDecorationTheme.fillColor);
    expect(
      decoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.controlRadius),
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
    videoPath: '/tmp/zoom-track.mov',
    durationMs: 1000,
  );
  await controller.init();
  addTearDown(controller.dispose);
  return controller;
}

Widget _buildZoomTrack({
  required ZoomEditorController editor,
  ValueChanged<int>? onQuickSeek,
}) {
  return MaterialApp(
    theme: buildDarkTheme(),
    darkTheme: buildDarkTheme(),
    themeMode: ThemeMode.dark,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 420,
          child: ListenableBuilder(
            listenable: editor,
            builder: (context, _) {
              return ZoomTrack(
                segments: editor.displaySegments,
                durationMs: 1000,
                positionMs: 0,
                onQuickSeek: onQuickSeek,
                editorController: editor,
              );
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _dragAcrossTrack(
  WidgetTester tester,
  Finder trackFinder, {
  required double startFraction,
  required double endFraction,
}) async {
  final rect = tester.getRect(trackFinder);
  final start = Offset(
    rect.left + (rect.width * startFraction),
    rect.center.dy,
  );
  final end = Offset(rect.left + (rect.width * endFraction), rect.center.dy);

  final gesture = await tester.startGesture(start);
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _tapAt(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 120));
}
