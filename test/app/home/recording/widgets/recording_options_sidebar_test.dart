import 'package:clingfy/app/home/recording/widgets/recording_options_sidebar.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestApp({
    int selectedIndex = 0,
    bool isRecording = false,
    DisplayTargetMode targetMode = DisplayTargetMode.explicitId,
    bool cursorEnabled = false,
    OverlayMode overlayMode = OverlayMode.off,
    String? selectedCamId = 'cam_1',
  }) {
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
              isRecording: isRecording,
              selectedIndex: selectedIndex,
              targetMode: targetMode,
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
              selectedCamId: selectedCamId,
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
              overlayMode: overlayMode,
              overlayShape: OverlayShape.squircle,
              overlaySize: 0.4,
              overlayShadow: OverlayShadow.medium,
              overlayBorder: OverlayBorder.none,
              overlayPosition: OverlayPosition.bottomRight,
              overlayUseCustomPosition: false,
              overlayRoundness: 0.5,
              indicatorPinned: false,
              cursorEnabled: cursorEnabled,
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

  testWidgets('screen tab renders three explicit settings groups', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 0));
    await tester.pumpAndSettle();

    expect(find.byType(AppSettingsGroup), findsNWidgets(3));
    expect(find.text('Capture Source'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Pointer'), findsOneWidget);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('screen tab source dropdowns fill the available control width', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 0));
    await tester.pumpAndSettle();

    final sourceGroup = find.ancestor(
      of: find.text('Capture Source'),
      matching: find.byType(AppSettingsGroup),
    );
    final sourceFields = find.descendant(
      of: sourceGroup,
      matching: find.byKey(PlatformDropdown.fieldKey),
    );

    expect(sourceFields, findsNWidgets(2));
    expect(
      tester.getSize(sourceFields.at(0)).width,
      greaterThan(AppSidebarTokens.controlMaxWidth),
    );
    expect(
      tester.getSize(sourceFields.at(1)).width,
      greaterThan(AppSidebarTokens.controlMaxWidth),
    );
  });

  testWidgets(
    'face cam tab keeps advanced groups hidden when overlay mode is off',
    (tester) async {
      await tester.pumpWidget(
        buildTestApp(selectedIndex: 1, overlayMode: OverlayMode.off),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppSettingsGroup), findsNWidgets(2));
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Visibility & Placement'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
      expect(find.text('Style'), findsNothing);
      expect(find.text('Effects'), findsNothing);
      expect(find.byType(Divider), findsNothing);
    },
  );

  testWidgets('face cam tab reveals grouped camera styling controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(selectedIndex: 1, overlayMode: OverlayMode.alwaysOn),
    );
    await tester.pumpAndSettle();

    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Visibility & Placement'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Style'), findsOneWidget);
    expect(find.text('Effects'), findsOneWidget);
  });

  testWidgets('output tab renders grouped recording and capture controls', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 2));
    await tester.pumpAndSettle();

    expect(find.byType(AppSettingsGroup), findsNWidgets(3));
    expect(find.text('Quality'), findsOneWidget);
    expect(find.text('Start & Stop'), findsOneWidget);
    expect(find.text('Capture Settings'), findsOneWidget);
    expect(find.byType(Divider), findsNothing);
    expect(
      find.byKey(const Key('recording_output_frame_rate_duration_gap')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('recording_output_frame_rate_duration_gap2')),
      findsNothing,
    );
  });

  testWidgets('output tab hides capture settings for single-window capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 2,
        targetMode: DisplayTargetMode.singleAppWindow,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Capture Settings'), findsNothing);
  });

  testWidgets(
    'screen tab exposes cursor hint as a conditional inline tooltip',
    (tester) async {
      await tester.pumpWidget(
        buildTestApp(selectedIndex: 0, cursorEnabled: true),
      );
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(RecordingOptionsSidebar)),
      )!;

      expect(find.byTooltip(l10n.cursorHint), findsOneWidget);
      expect(find.text(l10n.cursorHint), findsNothing);

      await tester.pumpWidget(
        buildTestApp(selectedIndex: 0, cursorEnabled: true, isRecording: true),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip(l10n.cursorHint), findsNothing);
    },
  );

  testWidgets('screen tab exposes area recording helper as a section tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 0,
        targetMode: DisplayTargetMode.areaRecording,
      ),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOptionsSidebar)),
    )!;

    expect(find.byTooltip(l10n.areaRecordingHelper), findsOneWidget);
    expect(find.text(l10n.areaRecordingHelper), findsNothing);
    expect(find.text(l10n.noAreaSelected), findsOneWidget);
  });
}
