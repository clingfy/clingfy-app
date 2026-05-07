import 'package:clingfy/app/home/post_processing/widgets/zoom_segment_behavior_floating_toolbar.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
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

  testWidgets(
    'renders pill when fixedTargetPreview supported and one segment is selected',
    (tester) async {
      final editor = await _createEditor(
        tester,
        fixedTargetPreview: true,
        manualSegments: const [_segmentMap],
      );
      addTearDown(editor.dispose);
      editor.selectOnly(editor.displaySegments.single);

      await tester.pumpWidget(_host(editor: editor));
      await tester.pumpAndSettle();

      final l10n = _l10n(tester);
      expect(find.text(l10n.zoomBehavior), findsOneWidget);
      expect(find.text(l10n.zoomFollowCursor), findsOneWidget);
      expect(find.text(l10n.zoomFixedTarget), findsOneWidget);
    },
  );

  testWidgets('returns shrunk widget when no segment is selected', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      fixedTargetPreview: true,
      manualSegments: const [_segmentMap],
    );
    addTearDown(editor.dispose);

    await tester.pumpWidget(_host(editor: editor));
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).zoomBehavior), findsNothing);
  });

  testWidgets('returns shrunk widget when multiple segments are selected', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      fixedTargetPreview: true,
      manualSegments: const [_segmentMap, _secondSegmentMap],
    );
    addTearDown(editor.dispose);
    for (final seg in editor.displaySegments) {
      editor.addToSelection(seg);
    }

    await tester.pumpWidget(_host(editor: editor));
    await tester.pumpAndSettle();

    expect(editor.canSingleEdit, isFalse);
    expect(find.text(_l10n(tester).zoomBehavior), findsNothing);
  });

  testWidgets(
    'returns shrunk widget when native does not support fixedTargetPreview',
    (tester) async {
      final editor = await _createEditor(
        tester,
        fixedTargetPreview: false,
        manualSegments: const [_segmentMap],
      );
      addTearDown(editor.dispose);
      editor.selectOnly(editor.displaySegments.single);

      await tester.pumpWidget(_host(editor: editor));
      await tester.pumpAndSettle();

      expect(editor.capabilities.fixedTargetPreview, isFalse);
      expect(find.text(_l10n(tester).zoomBehavior), findsNothing);
    },
  );

  testWidgets('tapping Fixed target switches the segment focus mode', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      fixedTargetPreview: true,
      manualSegments: const [_segmentMap],
    );
    addTearDown(editor.dispose);
    final segment = editor.displaySegments.single;
    editor.selectOnly(segment);
    expect(segment.focusMode, ZoomFocusMode.followCursor);

    await tester.pumpWidget(_host(editor: editor));
    await tester.pumpAndSettle();

    await tester.tap(find.text(_l10n(tester).zoomFixedTarget));
    await tester.pumpAndSettle();

    expect(editor.primarySelectedSegment!.focusMode, ZoomFocusMode.fixedTarget);
  });

  testWidgets('close button hides the pill until selection changes', (
    tester,
  ) async {
    final editor = await _createEditor(
      tester,
      fixedTargetPreview: true,
      manualSegments: const [_segmentMap, _secondSegmentMap],
    );
    addTearDown(editor.dispose);
    final segments = editor.displaySegments;
    editor.selectOnly(segments.first);

    await tester.pumpWidget(_host(editor: editor));
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).zoomBehavior), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('zoom_behavior_floating_toolbar_close')),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).zoomBehavior), findsNothing);

    // Re-selecting the same segment after a clear should bring the
    // pill back — dismissal is per-selection, not sticky.
    editor.clearSelection();
    await tester.pumpAndSettle();
    editor.selectOnly(segments.first);
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).zoomBehavior), findsOneWidget);

    // Dismiss again, then select a different segment — pill should
    // also reappear because primary selection changed.
    await tester.tap(
      find.byKey(const Key('zoom_behavior_floating_toolbar_close')),
    );
    await tester.pumpAndSettle();
    expect(find.text(_l10n(tester).zoomBehavior), findsNothing);

    editor.selectOnly(segments.last);
    await tester.pumpAndSettle();
    expect(find.text(_l10n(tester).zoomBehavior), findsOneWidget);
  });

  testWidgets(
    'static cursor hint surfaces for low-motion followCursor segments',
    (tester) async {
      final editor = await _createEditor(
        tester,
        fixedTargetPreview: true,
        cursorSamples: true,
        manualSegments: const [_segmentMap],
        emptyCursorSamples: true,
      );
      addTearDown(editor.dispose);
      editor.selectOnly(editor.displaySegments.single);

      await tester.pumpWidget(_host(editor: editor));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('zoom_behavior_floating_toolbar_static_hint')),
        findsOneWidget,
      );
    },
  );
}

const Map<String, Object?> _segmentMap = {
  'id': 'manual_seg_a',
  'startMs': 1000,
  'endMs': 4000,
  'source': 'manual',
  'focusMode': 'followCursor',
};

const Map<String, Object?> _secondSegmentMap = {
  'id': 'manual_seg_b',
  'startMs': 6000,
  'endMs': 9000,
  'source': 'manual',
  'focusMode': 'followCursor',
};

Future<ZoomEditorController> _createEditor(
  WidgetTester tester, {
  required bool fixedTargetPreview,
  bool cursorSamples = false,
  List<Map<String, Object?>> manualSegments = const [],
  bool emptyCursorSamples = false,
}) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
    switch (call.method) {
      case 'previewGetZoomCapabilities':
        return <String, dynamic>{
          'cursorSamples': cursorSamples,
          'fixedTargetPreview': fixedTargetPreview,
          'fixedTargetExport': fixedTargetPreview,
        };
      case 'previewGetSourceDimensions':
        return <String, dynamic>{'width': 1920.0, 'height': 1080.0};
      case 'getZoomSegments':
        return const <Map<String, Object?>>[];
      case 'getManualZoomSegments':
        return manualSegments;
      case 'saveManualZoomSegments':
        return true;
      case 'previewSetZoomSegments':
        return null;
      case 'previewGetCursorSamples':
        if (emptyCursorSamples) {
          return <String, dynamic>{
            'samples': <dynamic>[],
            'width': 1920.0,
            'height': 1080.0,
          };
        }
        return null;
      default:
        return null;
    }
  });

  final controller = ZoomEditorController(
    nativeBridge: NativeBridge.instance,
    videoPath: '/tmp/floating_toolbar.mov',
    durationMs: 60000,
    sessionId: 'test-session',
  );
  await controller.init();
  return controller;
}

Widget _host({required ZoomEditorController editor}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildDarkTheme(),
    darkTheme: buildDarkTheme(),
    themeMode: ThemeMode.dark,
    home: Scaffold(
      body: Center(
        child: ZoomSegmentBehaviorFloatingToolbar(
          editor: editor,
          nativeBridge: NativeBridge.instance,
          viewportController: TimelineViewportController(durationMs: 60000),
          durationMs: 60000,
          sessionId: 'test-session',
        ),
      ),
    ),
  );
}

AppLocalizations _l10n(WidgetTester tester) {
  return AppLocalizations.of(
    tester.element(find.byType(ZoomSegmentBehaviorFloatingToolbar)),
  )!;
}
