// The timeline viewport must actually be ON SCREEN on Windows, at a real
// window size, under the real density scope.
//
// Nothing covered that before: video_timeline_test.dart forces
// PlatformKind.macos in setUp, runs at the 800x600 test default, and supplies
// no ResponsiveShellScope — so the Windows branch at real window sizes had no
// coverage at all, and neither did the question "is the viewport where the user
// can see it", as opposed to "does the widget exist".
//
// Two failure modes these tests exist to catch, both of which look identical
// from the outside (the lane is simply not there) and neither of which trips a
// RenderFlex overflow:
//
//  1. A build exception inside the timeline subtree. Flutter substitutes an
//     ErrorWidget, and RenderErrorBox sizes itself to 100000px on an
//     unconstrained axis — so one throwing widget in the header bar shoves the
//     viewport ~100000px down while the header and transport above it keep
//     rendering normally. Measured: the viewport landed at y=100137 that way.
//     VideoTimeline's own Column is a non-flex child of the workspace Column
//     and therefore receives an unbounded maxHeight, so a RenderFlex overflow
//     error is structurally impossible there — the yellow stripes can never
//     fire and nothing is logged.
//
//  2. The viewport pushed past the pane's ClipRect. The timeline's bottom edge
//     sits exactly flush with the shell bottom by construction (the Expanded
//     preview area absorbs all slack), so there is zero headroom.
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/preview/widgets/video_timeline.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../../../test_helpers/native_test_setup.dart';

/// `HomeDesktopPaneDimensions.innerGap`.
const double _innerGap = 4;

/// A real window height the editor is used at, and the one the clips-lane
/// investigation measured against.
const double _windowHeight = 830;
const Size _surface = Size(1550, _windowHeight);

/// The shell box is the window minus home_shell.dart's two outer paddings
/// (`EdgeInsets.all(2)` at :495 and `EdgeInsets.all(6)` at :503) = 16px.
/// Modelled below rather than hardcoded, but named here for the assertions.
const double _outerPadding = 16;
const double _shellHeight = _windowHeight - _outerPadding;

/// Comfortably below the toolbar height at which the Expanded preview area
/// collapses to zero (measured threshold: 531.2 at this shell height).
const double _toolbarHeight = 46;

void main() {
  setUp(() async {
    await installCommonNativeMocks();
  });
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  /// Mounts VideoTimeline inside the real vertical chain rather than in
  /// isolation: the pane layout's ClipRect and its tight-height Row are what
  /// decide whether the viewport is visible, and none of them exist when the
  /// widget is pumped on its own.
  Future<void> pumpChain(
    WidgetTester tester, {
    required PlatformKind platform,
    double toolbarHeight = _toolbarHeight,
  }) async {
    debugPlatformKindOverride = platform;
    tester.view.physicalSize = _surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final clipEditor = ClipEditorController(
      nativeBridge: NativeBridge.instance,
      durationMs: 26082,
      sessionId: 'timeline-visibility',
    );
    addTearDown(clipEditor.dispose);
    final player = _FakePlayer(clipEditor: clipEditor);
    addTearDown(player.dispose);
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    addTearDown(settings.dispose);
    final postPlayer = PlayerController(nativeBridge: NativeBridge.instance);
    addTearDown(postPlayer.dispose);
    final post = PostProcessingController(
      settings: settings,
      player: postPlayer,
      channel: NativeBridge.instance,
    );
    addTearDown(post.dispose);
    final paneController = DesktopPaneController();
    addTearDown(paneController.dispose);

    final workspaceColumn = Column(
      key: const Key('home_workspace_column'),
      children: [
        SizedBox(height: toolbarHeight, width: double.infinity),
        const SizedBox(height: _innerGap),
        const Expanded(child: SizedBox(width: 100)),
        const SizedBox(height: _innerGap),
        VideoTimeline(
          durationMs: 26082,
          positionMs: 5000,
          isReady: true,
          editingEnabled: true,
          onSeek: (_) {},
          onHoverSeek: (_) {},
          onHoverEnd: () {},
        ),
      ],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<PostProcessingController>.value(value: post),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildDarkTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: ThemeMode.dark,
          home: fluent.FluentTheme(
            data: fluent.FluentThemeData(brightness: Brightness.dark),
            child: ResponsiveShellScope(
              metrics: ShellResponsiveMetrics.fromSize(_surface),
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: SizedBox(
                      height: _shellHeight,
                      child: DesktopSplitLayout(
                        controller: paneController,
                        gap: _innerGap,
                        minHeight: 592,
                        panes: [
                          DesktopPaneSlot(
                            spec: const DesktopPaneSpec(
                              id: DesktopPaneId.homeWorkspaceColumn,
                              defaultWidth: 1040,
                              minWidth: 760,
                              autoCollapseAllowed: false,
                              flex: true,
                            ),
                            builder: (context, _) => workspaceColumn,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final platform in <PlatformKind>[
    PlatformKind.windows,
    PlatformKind.macos,
  ]) {
    final name = platform.name;

    testWidgets(
      '$name: the timeline viewport is on screen, not below the fold',
      (tester) async {
        await pumpChain(tester, platform: platform);

        final viewport = find.byKey(const Key('timeline_editor_viewport'));
        expect(viewport, findsOneWidget);

        final rect = tester.getRect(viewport);
        expect(
          rect.height,
          greaterThan(0),
          reason:
              'the viewport height is intrinsic and floored by '
              'ShellResponsiveMetrics; zero means the metrics collapsed',
        );
        // The real assertion. A viewport at y=100137 (the ErrorWidget case) or
        // shoved past the pane clip both land here, and neither raises anything
        // on its own.
        expect(
          rect.top,
          lessThan(_shellHeight),
          reason:
              'the viewport was pushed below the shell bottom — it is laid '
              'out but the user cannot see it',
        );
        expect(rect.top, greaterThanOrEqualTo(0));
      },
    );

    testWidgets('$name: the clips lane and its clip rectangles are visible', (
      tester,
    ) async {
      await pumpChain(tester, platform: platform);

      final lane = find.byKey(const Key('clips_timeline_lane'));
      expect(lane, findsOneWidget);

      final laneRect = tester.getRect(lane);
      expect(laneRect.height, greaterThan(0));
      expect(
        laneRect.top,
        lessThan(_shellHeight),
        reason: 'the clips lane is off screen',
      );

      // The lane being present is not enough — it must actually draw the clip.
      final clips = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
              'clips_timeline_lane_clip_',
            ),
      );
      expect(
        clips,
        findsWidgets,
        reason: 'the lane rendered no clip rectangles for a 1-clip editor',
      );
      final clipRect = tester.getRect(clips.first);
      expect(clipRect.width, greaterThan(0));
      expect(clipRect.height, greaterThan(0));
      expect(clipRect.top, lessThan(_shellHeight));
    });

    testWidgets('$name: nothing in the timeline subtree throws during build', (
      tester,
    ) async {
      await pumpChain(tester, platform: platform);

      // A throwing widget becomes an ErrorWidget whose RenderErrorBox is
      // 100000px tall on an unconstrained axis, which silently relocates every
      // later sibling — including the viewport — off screen. Catch the cause
      // here rather than the symptom.
      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason:
            'a build exception in the timeline subtree substitutes a '
            '100000px ErrorWidget and pushes the viewport off screen',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the workspace column reports an overflow rather than hiding the '
      'timeline silently', (tester) async {
    // The escape hatch that makes the above trustworthy: when the preview area
    // really is squeezed to zero, this chain DOES raise. Measured threshold at
    // this shell height is a toolbar above 531.2px.
    await pumpChain(tester, platform: PlatformKind.windows, toolbarHeight: 600);

    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    expect('$error', contains('overflowed'));
  });
}

class _FakePlayer extends PlayerController {
  _FakePlayer({required ClipEditorController clipEditor})
    : _clipEditor = clipEditor,
      super(nativeBridge: NativeBridge.instance);

  final ClipEditorController _clipEditor;

  @override
  ClipEditorController? get clipEditor => _clipEditor;

  @override
  int get durationMs => 26082;

  @override
  int get positionMs => 5000;

  @override
  bool get isReady => true;
}
