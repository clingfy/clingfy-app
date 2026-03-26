import 'dart:io';

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_section.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_processing_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestApp({
    int selectedIndex = 0,
    bool enabled = true,
    bool cursorAvailable = true,
    bool hasAudio = true,
    bool showCursor = true,
    double zoomFactor = 1.0,
    bool autoNormalizeOnExport = false,
    String? backgroundImagePath,
    void Function(double)? onZoomFactorChanged,
    void Function(double)? onZoomFactorChangeEnd,
    void Function(String?)? onBackgroundImageChanged,
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
          body: PostProcessingSidebar(
            selectedIndex: selectedIndex,
            isProcessing: false,
            enabled: enabled,
            layoutPreset: LayoutPreset.auto,
            resolutionPreset: ResolutionPreset.auto,
            fitMode: FitMode.fit,
            padding: 8,
            radius: 4,
            backgroundColor: 0xFFFFFFFF,
            backgroundImagePath: backgroundImagePath,
            showCursor: showCursor,
            cursorSize: 1.0,
            zoomFactor: zoomFactor,
            cursorAvailable: cursorAvailable,
            hasAudio: hasAudio,
            disabledMessage: null,
            audioGainDb: 0,
            audioVolume: 50,
            autoNormalizeOnExport: autoNormalizeOnExport,
            autoNormalizeTargetDbfs: -14,
            onLayoutPresetChanged: (_) {},
            onResolutionPresetChanged: (_) {},
            onFitModeChanged: (_) {},
            onPaddingChanged: (_) {},
            onPaddingChangeEnd: (_) {},
            onRadiusChanged: (_) {},
            onRadiusChangeEnd: (_) {},
            onBackgroundColorChanged: (_) {},
            onBackgroundImageChanged: onBackgroundImageChanged ?? (_) {},
            onCursorShowChanged: (_) {},
            onCursorSizeChanged: (_) {},
            onCursorSizeChangeEnd: (_) {},
            onZoomFactorChanged: onZoomFactorChanged ?? (_) {},
            onZoomFactorChangeEnd: onZoomFactorChangeEnd ?? (_) {},
            onPickImage: () async => null,
            onAudioGainChanged: (_) {},
            onAudioGainChangeEnd: (_) {},
            onAudioVolumeChanged: (_) {},
            onAudioVolumeChangeEnd: (_) {},
            onAutoNormalizeOnExportChanged: (_) {},
            onAutoNormalizeTargetDbfsChanged: (_) {},
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

      expect(find.byKey(const Key('post_sidebar_rail')), findsNothing);
      expect(find.text('Layout Settings'), findsOneWidget);

      await tester.pumpWidget(buildTestApp(selectedIndex: 1));
      await tester.pumpAndSettle();
      expect(find.text('Effects Settings'), findsOneWidget);

      await tester.pumpWidget(buildTestApp(selectedIndex: 2));
      await tester.pumpAndSettle();
      expect(find.text('Export Settings'), findsOneWidget);
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
              return PostProcessingSidebarRail(
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
      find.byKey(const ValueKey('post_sidebar_rail_tile_0')),
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
    expect(find.text('Layout'), findsNothing);
    expect(find.text('Effects'), findsNothing);
    expect(find.text('Export'), findsNothing);
    expect(
      find.byTooltip(
        AppLocalizations.of(tester.element(find.byType(Scaffold)))!.effects,
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('post_sidebar_rail_tile_1')));
    await tester.pumpAndSettle();

    final selectedButtonAfter = tester.widget<IconButton>(
      find.byKey(const ValueKey('post_sidebar_rail_tile_1')),
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
      find.byKey(const ValueKey('post_sidebar_rail_tile_1')),
    );
    expect(
      semantics.label,
      AppLocalizations.of(tester.element(find.byType(Scaffold)))!.effects,
    );
  });

  testWidgets('layout tab uses app section and slider primitives', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    expect(find.byType(AppSection), findsWidgets);
    expect(find.byType(AppSliderRow), findsNWidgets(2));
    expect(find.byType(AppSlider), findsNWidgets(2));
    expect(find.text('Pick an image'), findsOneWidget);
    expect(find.text('More colors'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'SectionCard',
      ),
      findsNothing,
    );
  });

  testWidgets('background image preview uses app icon button clear action', (
    tester,
  ) async {
    final cleared = <String?>[];
    final imagePath =
        '${Directory.current.path}/assets/images/app-banner-macos.png';

    expect(File(imagePath).existsSync(), isTrue);

    await tester.pumpWidget(
      buildTestApp(
        backgroundImagePath: imagePath,
        onBackgroundImageChanged: cleared.add,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppIconButton), findsOneWidget);
    expect(find.text('app-banner-macos.png'), findsWidgets);

    final clearButton = tester.widget<AppIconButton>(
      find.byType(AppIconButton),
    );
    clearButton.onPressed?.call();

    expect(cleared, [null]);
  });

  testWidgets('effects tab shows standardized notices when data is missing', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        cursorAvailable: false,
        hasAudio: false,
        showCursor: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppInlineNotice), findsNWidgets(2));
    expect(find.text('Cursor data missing'), findsOneWidget);
    expect(find.text('No mic audio track found'), findsOneWidget);
  });

  testWidgets('effects tab exposes zoom and cursor helper copy as tooltips', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 1));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Toggle cursor visibility'), findsOneWidget);
    expect(find.text('Toggle cursor visibility'), findsNothing);
    expect(find.byTooltip('Manage zoom in effects'), findsOneWidget);
    expect(find.text('Manage zoom in effects'), findsNothing);
  });

  testWidgets('export tab only shows normalization controls', (tester) async {
    await tester.pumpWidget(
      buildTestApp(selectedIndex: 2, autoNormalizeOnExport: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('Format'), findsNothing);
    expect(find.text('Codec'), findsNothing);
    expect(find.text('Bitrate'), findsNothing);
    expect(find.text('Auto-normalize on export'), findsOneWidget);
    expect(find.text('Target loudness'), findsNothing);

    await tester.pumpWidget(
      buildTestApp(selectedIndex: 2, autoNormalizeOnExport: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Format'), findsNothing);
    expect(find.text('Codec'), findsNothing);
    expect(find.text('Bitrate'), findsNothing);
    expect(find.text('Target loudness'), findsOneWidget);
  });

  testWidgets('zoom toggle preserves enable/disable callback behavior', (
    tester,
  ) async {
    final changed = <double>[];
    final ended = <double>[];

    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        zoomFactor: 1.0,
        onZoomFactorChanged: changed.add,
        onZoomFactorChangeEnd: ended.add,
      ),
    );
    await tester.pumpAndSettle();

    final toggleRows = find.byType(AppToggleRow);
    expect(toggleRows, findsNWidgets(2));

    final zoomToggle = tester.widget<AppToggleRow>(toggleRows.at(1));
    zoomToggle.onChanged?.call(true);

    expect(changed.last, 1.5);
    expect(ended.last, 1.5);

    changed.clear();
    ended.clear();

    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        zoomFactor: 2.0,
        onZoomFactorChanged: changed.add,
        onZoomFactorChangeEnd: ended.add,
      ),
    );
    await tester.pumpAndSettle();

    final zoomToggleEnabled = tester.widget<AppToggleRow>(
      find.byType(AppToggleRow).at(1),
    );
    zoomToggleEnabled.onChanged?.call(false);

    expect(changed.last, 1.0);
    expect(ended.last, 1.0);
  });

  testWidgets('disabled state keeps content interaction blocked', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(enabled: false));
    await tester.pumpAndSettle();

    final dimmedOpacity = find.byWidgetPredicate(
      (widget) => widget is Opacity && (widget.opacity - 0.45).abs() < 0.0001,
    );
    final blockedIgnorePointer = find.byWidgetPredicate(
      (widget) => widget is IgnorePointer && widget.ignoring,
    );

    expect(dimmedOpacity, findsOneWidget);
    expect(blockedIgnorePointer, findsOneWidget);
  });

  testWidgets('background color picker dialog opens without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('More colors'));
    await tester.pumpAndSettle();

    expect(find.byType(ColorPicker), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('header leaves consistent breathing room before tab content', (
    tester,
  ) async {
    Future<void> expectGap(int selectedIndex) async {
      await tester.pumpWidget(buildTestApp(selectedIndex: selectedIndex));
      await tester.pumpAndSettle();

      final topSpacer = tester.widget<SizedBox>(
        find.byKey(const Key('post_sidebar_top_spacer')),
      );
      expect(topSpacer.height, AppSidebarTokens.headerContentGap);
    }

    await expectGap(0);
    await expectGap(1);
    await expectGap(2);
  });

  testWidgets('layout tab uses the new group spacing around background', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 0));
    await tester.pumpAndSettle();

    final backgroundGapBeforeDivider = tester.widget<SizedBox>(
      find.byKey(const Key('post_layout_background_gap_before_divider')),
    );
    final backgroundGapAfterDivider = tester.widget<SizedBox>(
      find.byKey(const Key('post_layout_background_gap_after_divider')),
    );
    final controlsGapBeforeDivider = tester.widget<SizedBox>(
      find.byKey(const Key('post_layout_controls_gap_before_divider')),
    );
    final controlsGapAfterDivider = tester.widget<SizedBox>(
      find.byKey(const Key('post_layout_controls_gap_after_divider')),
    );

    expect(backgroundGapBeforeDivider.height, AppSidebarTokens.optionsGroupGap);
    expect(backgroundGapAfterDivider.height, AppSidebarTokens.optionsGroupGap);
    expect(
      controlsGapBeforeDivider.height,
      AppSidebarTokens.optionsSubgroupGap,
    );
    expect(controlsGapAfterDivider.height, AppSidebarTokens.optionsSubgroupGap);
  });

  testWidgets(
    'effects tab uses the new spacing between cursor, zoom, and audio',
    (tester) async {
      await tester.pumpWidget(
        buildTestApp(selectedIndex: 1, showCursor: true, zoomFactor: 2.0),
      );
      await tester.pumpAndSettle();

      final cursorZoomGap = tester.widget<SizedBox>(
        find.byKey(const Key('post_effects_cursor_zoom_gap')),
      );
      final audioGapBeforeDivider = tester.widget<SizedBox>(
        find.byKey(const Key('post_effects_audio_gap_before_divider')),
      );
      final audioGapAfterDivider = tester.widget<SizedBox>(
        find.byKey(const Key('post_effects_audio_gap_after_divider')),
      );
      final cursorSizeGap = tester.widget<SizedBox>(
        find.byKey(const Key('post_cursor_size_gap')),
      );
      final zoomIntensityGap = tester.widget<SizedBox>(
        find.byKey(const Key('post_zoom_intensity_gap')),
      );

      expect(cursorZoomGap.height, AppSidebarTokens.optionsGroupGap);
      expect(audioGapBeforeDivider.height, AppSidebarTokens.optionsSubgroupGap);
      expect(audioGapAfterDivider.height, AppSidebarTokens.optionsGroupGap);
      expect(cursorSizeGap.height, AppSidebarTokens.optionsSubgroupGap);
      expect(zoomIntensityGap.height, AppSidebarTokens.optionsSubgroupGap);
    },
  );

  testWidgets('export tab uses the new spacing before normalization controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(selectedIndex: 2, autoNormalizeOnExport: true),
    );
    await tester.pumpAndSettle();

    final spacer = tester.widget<SizedBox>(
      find.byKey(const Key('post_export_target_loudness_gap')),
    );

    expect(spacer.height, AppSidebarTokens.optionsSubgroupGap);
  });
}
