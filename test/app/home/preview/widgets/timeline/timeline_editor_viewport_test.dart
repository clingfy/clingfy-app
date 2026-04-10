import 'dart:ui';

import 'package:clingfy/app/home/preview/widgets/timeline/timeline_editor_viewport.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  testWidgets('pan mode drag pans viewport and blocks ruler seek and hover', (
    tester,
  ) async {
    final viewportController = TimelineViewportController(durationMs: 60000);
    var seekCalls = 0;
    var hoverCalls = 0;

    await tester.pumpWidget(
      _buildViewport(
        viewportController: viewportController,
        panModeEnabled: true,
        onSeek: (_) => seekCalls += 1,
        onHoverSeek: (_) => hoverCalls += 1,
      ),
    );

    viewportController.setZoomLevel(4);
    await tester.pump();

    final overlayFinder = find.byKey(const Key('timeline_pan_overlay'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(overlayFinder));
    await mouse.moveTo(tester.getCenter(overlayFinder));
    await tester.pump();

    expect(hoverCalls, 0);

    final gesture = await tester.startGesture(tester.getCenter(overlayFinder));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    await gesture.up();

    expect(viewportController.scrollOffset, greaterThan(0));
    expect(seekCalls, 0);
  });

  testWidgets('pan mode cursor switches between grab and grabbing', (
    tester,
  ) async {
    final viewportController = TimelineViewportController(durationMs: 60000);

    await tester.pumpWidget(
      _buildViewport(
        viewportController: viewportController,
        panModeEnabled: true,
      ),
    );

    viewportController.setZoomLevel(3);
    await tester.pump();

    final overlayFinder = find.byKey(const Key('timeline_pan_overlay'));
    expect(
      tester.widget<MouseRegion>(overlayFinder).cursor,
      SystemMouseCursors.grab,
    );

    final gesture = await tester.startGesture(tester.getCenter(overlayFinder));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();

    expect(
      tester.widget<MouseRegion>(overlayFinder).cursor,
      SystemMouseCursors.grabbing,
    );

    await gesture.up();
    await tester.pump();

    expect(
      tester.widget<MouseRegion>(overlayFinder).cursor,
      SystemMouseCursors.grab,
    );
  });

  testWidgets('pan mode blocks zoom lane editing gestures', (tester) async {
    final viewportController = TimelineViewportController(durationMs: 60000);
    final editor = await _createEditor(tester);

    await tester.pumpWidget(
      _buildViewport(
        viewportController: viewportController,
        panModeEnabled: true,
        editor: editor,
      ),
    );

    viewportController.setZoomLevel(4);
    editor.enterOneShotAddMode();
    await tester.pump();

    final laneFinder = find.byKey(const Key('zoom_track_shell'));
    final laneRect = tester.getRect(laneFinder);
    final gesture = await tester.startGesture(
      Offset(laneRect.left + 40, laneRect.center.dy),
    );
    await gesture.moveTo(Offset(laneRect.left + 220, laneRect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(editor.draftSegment, isNull);
    expect(editor.displaySegments, isEmpty);
    expect(viewportController.scrollOffset, greaterThan(0));
  });

  testWidgets('without pan mode ruler drag still seeks normally', (
    tester,
  ) async {
    final viewportController = TimelineViewportController(durationMs: 60000);
    var seekCalls = 0;

    await tester.pumpWidget(
      _buildViewport(
        viewportController: viewportController,
        panModeEnabled: false,
        onSeek: (_) => seekCalls += 1,
      ),
    );

    viewportController.setZoomLevel(3);
    await tester.pump();

    final rulerFinder = find.byKey(const Key('timeline_ruler_strip'));
    await tester.drag(rulerFinder, const Offset(80, 0));
    await tester.pump();

    expect(seekCalls, greaterThan(0));
    expect(find.byKey(const Key('timeline_pan_overlay')), findsNothing);
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
    videoPath: '/tmp/timeline-editor-viewport.mov',
    durationMs: 60000,
  );
  await controller.init();
  addTearDown(controller.dispose);
  return controller;
}

Widget _buildViewport({
  required TimelineViewportController viewportController,
  required bool panModeEnabled,
  ZoomEditorController? editor,
  ValueChanged<int>? onSeek,
  ValueChanged<int>? onHoverSeek,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildDarkTheme(),
    darkTheme: buildDarkTheme(),
    themeMode: ThemeMode.dark,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 640,
          child: TimelineEditorViewport(
            durationMs: 60000,
            positionMs: 15000,
            viewportController: viewportController,
            segments: editor?.displaySegments ?? const [],
            editorController: editor,
            showZoomLane: true,
            showMarkersLane: true,
            panModeEnabled: panModeEnabled,
            onSeek: onSeek ?? (_) {},
            onHoverSeek: onHoverSeek,
            onHoverEnd: () {},
            onHoverChanged: (_) {},
            hoverPositionMs: null,
            onFocusRequested: () {},
          ),
        ),
      ),
    ),
  );
}
