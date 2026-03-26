import 'package:clingfy/app/home/recording/widgets/recording_options_sidebar.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_section.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestApp({int selectedIndex = 0}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: MacosTheme(
        data: buildMacosTheme(Brightness.dark),
        child: Scaffold(
          body: SizedBox(
            width: 960,
            child: RecordingOptionsSidebar(
              isRecording: false,
              selectedIndex: selectedIndex,
              targetMode: DisplayTargetMode.explicitId,
              displays: const [],
              selectedDisplayId: null,
              appWindows: const [],
              selectedAppWindowId: null,
              loadingAppWindows: false,
              audioSources: const [],
              selectedAudioSourceId: '__none__',
              loadingAudio: false,
              systemAudioEnabled: false,
              cams: const [CamSource(id: 'cam_1', name: 'Cam')],
              selectedCamId: 'cam_1',
              loadingCams: false,
              areaDisplayId: null,
              areaRect: null,
              onTargetModeChanged: (_) {},
              onDisplayChanged: (_) {},
              onRefreshDisplays: () {},
              onAppWindowChanged: (_) {},
              onRefreshAppWindows: () {},
              onAudioSourceChanged: (_) {},
              onRefreshAudio: () {},
              onSystemAudioEnabledChanged: (_) {},
              excludeMicFromSystemAudio: false,
              onExcludeMicFromSystemAudioChanged: (_) {},
              onCamSourceChanged: (_) {},
              onRefreshCams: () {},
              onPickArea: () {},
              onRevealArea: () {},
              onClearArea: () {},
              captureFrameRate: 60,
              autoStopEnabled: false,
              autoStopAfter: const Duration(minutes: 10),
              countdownEnabled: false,
              countdownDuration: 3,
              onFrameRateChanged: (_) {},
              onAutoStopEnabledChanged: (_) {},
              onAutoStopAfterChanged: (_) {},
              onCountdownEnabledChanged: (_) {},
              onCountdownDurationChanged: (_) {},
              excludeRecorderAppFromCapture: false,
              onExcludeRecorderAppFromCaptureChanged: (_) {},
              overlayMode: OverlayMode.off,
              overlayShape: OverlayShape.squircle,
              overlaySize: 0.4,
              overlayShadow: OverlayShadow.medium,
              overlayBorder: OverlayBorder.none,
              overlayPosition: OverlayPosition.bottomRight,
              overlayUseCustomPosition: false,
              overlayRoundness: 0.5,
              indicatorPinned: false,
              cursorEnabled: false,
              cursorLinkedToRecording: true,
              onOverlayModeChanged: (_) {},
              onOverlayShapeChanged: (_) {},
              onOverlaySizeChanged: (_) {},
              onOverlayShadowChanged: (_) {},
              onOverlayBorderChanged: (_) {},
              onOverlayPositionChanged: (_) {},
              onOverlayRoundnessChanged: (_) {},
              overlayOpacity: 1,
              onOverlayOpacityChanged: (_) {},
              overlayMirror: false,
              onOverlayMirrorChanged: (_) {},
              overlayRecordingHighlightEnabled: false,
              overlayRecordingHighlightStrength: 0.5,
              onOverlayRecordingHighlightEnabledChanged: (_) {},
              onOverlayRecordingHighlightStrengthChanged: (_) {},
              overlayBorderWidth: 2,
              overlayBorderColor: 0xFFFFFFFF.toSigned(32),
              onOverlayBorderWidthChanged: (_) {},
              onOverlayBorderColorChanged: (_) {},
              chromaKeyEnabled: false,
              chromaKeyStrength: 0.5,
              chromaKeyColor: 0xFF00FF00.toSigned(32),
              onChromaKeyEnabledChanged: (_) {},
              onChromaKeyStrengthChanged: (_) {},
              onChromaKeyColorChanged: (_) {},
              onIndicatorPinnedChanged: (_) {},
              onCursorModeChanged: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'options panel renders selected content without an embedded rail',
    (tester) async {
      await tester.pumpWidget(buildTestApp(selectedIndex: 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('recording_sidebar_rail')), findsNothing);
      expect(find.byKey(const Key('recording_sidebar_header')), findsOneWidget);
      expect(find.text('Screen & Audio'), findsOneWidget);
      expect(find.text('Face Cam'), findsNothing);
      expect(find.text('Output'), findsNothing);

      await tester.pumpWidget(buildTestApp(selectedIndex: 1));

      await tester.pumpAndSettle();

      expect(find.text('Face Cam'), findsOneWidget);
      expect(find.text('Output'), findsNothing);
    },
  );

  testWidgets('standalone rail updates the selected tile on tap', (
    tester,
  ) async {
    final theme = buildDarkTheme();
    var selectedIndex = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: theme,
        darkTheme: theme,
        themeMode: ThemeMode.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return RecordingSidebarRail(
                selectedIndex: selectedIndex,
                onSelectedIndexChanged: (value) {
                  setState(() => selectedIndex = value);
                },
              );
            },
          ),
        ),
      ),
    );

    final selectedButtonBefore = tester.widget<IconButton>(
      find.byKey(const ValueKey('recording_sidebar_rail_tile_0')),
    );
    expect(selectedButtonBefore.iconSize, 28);
    expect(selectedButtonBefore.isSelected, isTrue);
    expect(
      selectedButtonBefore.style?.backgroundColor?.resolve({}),
      Colors.transparent,
    );
    expect(
      selectedButtonBefore.style?.foregroundColor?.resolve({
        WidgetState.selected,
      }),
      theme.colorScheme.onSurface,
    );
    expect(find.text('Screen & Audio'), findsNothing);
    expect(find.text('Face Cam'), findsNothing);
    expect(find.text('Output'), findsNothing);
    expect(
      find.byTooltip(
        AppLocalizations.of(tester.element(find.byType(Scaffold)))!.tabFaceCam,
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('recording_sidebar_rail_tile_1')),
    );
    await tester.pumpAndSettle();

    final selectedButtonAfter = tester.widget<IconButton>(
      find.byKey(const ValueKey('recording_sidebar_rail_tile_1')),
    );
    expect(selectedButtonAfter.iconSize, 28);
    expect(selectedButtonAfter.isSelected, isTrue);
    expect(
      selectedButtonAfter.style?.foregroundColor?.resolve({
        WidgetState.selected,
      }),
      theme.colorScheme.onSurface,
    );
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('recording_sidebar_rail_tile_1')),
    );
    expect(
      semantics.label,
      AppLocalizations.of(tester.element(find.byType(Scaffold)))!.tabFaceCam,
    );
  });

  testWidgets('options panel uses a compact bottom spacer', (tester) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 0));
    await tester.pumpAndSettle();

    final bottomSpacer = tester.widget<SizedBox>(
      find.byKey(const Key('recording_sidebar_bottom_spacer')),
    );

    expect(bottomSpacer.height, AppSidebarTokens.rowGap);
  });

  testWidgets('header leaves consistent breathing room before tab content', (
    tester,
  ) async {
    Future<void> expectGap(int selectedIndex) async {
      await tester.pumpWidget(buildTestApp(selectedIndex: selectedIndex));
      await tester.pumpAndSettle();

      final topSpacer = tester.widget<SizedBox>(
        find.byKey(const Key('recording_sidebar_top_spacer')),
      );
      expect(topSpacer.height, AppSidebarTokens.headerContentGap);
    }

    await expectGap(0);
    await expectGap(1);
    await expectGap(2);
  });

  testWidgets('dropdown-backed sections use the larger title spacing', (
    tester,
  ) async {
    Future<void> expectTitleSpacing({
      required int selectedIndex,
      required String title,
    }) async {
      await tester.pumpWidget(buildTestApp(selectedIndex: selectedIndex));
      await tester.pumpAndSettle();

      final section = tester.widget<AppSection>(
        find.byWidgetPredicate(
          (widget) => widget is AppSection && widget.title == title,
        ),
      );

      expect(section.titleSpacing, AppSidebarTokens.dropdownSectionTitleGap);
    }

    await expectTitleSpacing(selectedIndex: 0, title: 'Audio');
    await expectTitleSpacing(selectedIndex: 0, title: 'Display');
    await expectTitleSpacing(selectedIndex: 1, title: 'Camera');
    await expectTitleSpacing(selectedIndex: 2, title: 'Duration');
  });
}
