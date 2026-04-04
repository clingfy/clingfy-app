import 'dart:io';

import 'package:clingfy/app/home/post_processing/widgets/post_processing_sidebar.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestApp({
    int selectedIndex = 0,
    bool isProcessing = false,
    bool enabled = true,
    bool cursorAvailable = true,
    bool hasAudio = true,
    bool showCursor = true,
    double zoomFactor = 1.0,
    bool autoNormalizeOnExport = false,
    double? sidebarWidth,
    LayoutPreset layoutPreset = LayoutPreset.auto,
    ResolutionPreset resolutionPreset = ResolutionPreset.auto,
    String? backgroundImagePath,
    bool hasCameraAsset = false,
    CameraExportCapabilities cameraExportCapabilities =
        const CameraExportCapabilities.allSupported(),
    CameraCompositionState? cameraState,
    void Function(LayoutPreset)? onLayoutPresetChanged,
    void Function(ResolutionPreset)? onResolutionPresetChanged,
    void Function(double)? onZoomFactorChanged,
    void Function(double)? onZoomFactorChangeEnd,
    void Function(CameraZoomBehavior)? onCameraZoomBehaviorChanged,
    void Function(double)? onCameraZoomScaleMultiplierChanged,
    void Function(double)? onCameraZoomScaleMultiplierChangeEnd,
    void Function(CameraLayoutPreset)? onCameraLayoutPresetChanged,
    void Function(Offset)? onCameraManualCenterChanged,
    void Function(Offset)? onCameraManualCenterChangeEnd,
    void Function(String?)? onBackgroundImageChanged,
  }) {
    final sidebar = PostProcessingSidebar(
      selectedIndex: selectedIndex,
      isProcessing: isProcessing,
      enabled: enabled,
      layoutPreset: layoutPreset,
      resolutionPreset: resolutionPreset,
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
      onLayoutPresetChanged: onLayoutPresetChanged ?? (_) {},
      onResolutionPresetChanged: onResolutionPresetChanged ?? (_) {},
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
      hasCameraAsset: hasCameraAsset,
      cameraExportCapabilities: cameraExportCapabilities,
      cameraState: cameraState,
      onCameraVisibleChanged: (_) {},
      onCameraLayoutPresetChanged: onCameraLayoutPresetChanged ?? (_) {},
      onCameraSizeFactorChanged: (_) {},
      onCameraSizeFactorChangeEnd: (_) {},
      onCameraShapeChanged: (_) {},
      onCameraCornerRadiusChanged: (_) {},
      onCameraCornerRadiusChangeEnd: (_) {},
      onCameraMirrorChanged: (_) {},
      onCameraContentModeChanged: (_) {},
      onCameraZoomBehaviorChanged: onCameraZoomBehaviorChanged ?? (_) {},
      onCameraZoomScaleMultiplierChanged:
          onCameraZoomScaleMultiplierChanged ?? (_) {},
      onCameraZoomScaleMultiplierChangeEnd:
          onCameraZoomScaleMultiplierChangeEnd ?? (_) {},
      onCameraIntroPresetChanged: (_) {},
      onCameraOutroPresetChanged: (_) {},
      onCameraZoomEmphasisPresetChanged: (_) {},
      onCameraIntroDurationChanged: (_) {},
      onCameraIntroDurationChangeEnd: (_) {},
      onCameraOutroDurationChanged: (_) {},
      onCameraOutroDurationChangeEnd: (_) {},
      onCameraZoomEmphasisStrengthChanged: (_) {},
      onCameraZoomEmphasisStrengthChangeEnd: (_) {},
      onCameraManualCenterChanged: onCameraManualCenterChanged ?? (_) {},
      onCameraManualCenterChangeEnd: onCameraManualCenterChangeEnd ?? (_) {},
      onAudioGainChanged: (_) {},
      onAudioGainChangeEnd: (_) {},
      onAudioVolumeChanged: (_) {},
      onAudioVolumeChangeEnd: (_) {},
      onAutoNormalizeOnExportChanged: (_) {},
      onAutoNormalizeTargetDbfsChanged: (_) {},
    );

    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: MacosTheme(
        data: buildMacosTheme(Brightness.dark),
        child: Scaffold(
          body: sidebarWidth == null
              ? sidebar
              : Center(
                  child: SizedBox(width: sidebarWidth, child: sidebar),
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
      expect(find.text('Canvas Settings'), findsOneWidget);

      await tester.pumpWidget(buildTestApp(selectedIndex: 1));
      await tester.pumpAndSettle();
      expect(find.text('Camera Settings'), findsOneWidget);

      await tester.pumpWidget(buildTestApp(selectedIndex: 2));
      await tester.pumpAndSettle();
      expect(find.text('Effects Settings'), findsOneWidget);

      await tester.pumpWidget(buildTestApp(selectedIndex: 3));
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
    expect(find.text('Canvas'), findsNothing);
    expect(find.text('Camera'), findsNothing);
    expect(find.text('Effects'), findsNothing);
    expect(find.text('Export'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('post_sidebar_rail_tile_2')));
    await tester.pumpAndSettle();

    final selectedButtonAfter = tester.widget<IconButton>(
      find.byKey(const ValueKey('post_sidebar_rail_tile_2')),
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
      find.byKey(const ValueKey('post_sidebar_rail_tile_2')),
    );
    expect(
      semantics.label,
      AppLocalizations.of(tester.element(find.byType(Scaffold)))!.effects,
    );
  });

  testWidgets(
    'canvas tab uses grouped hierarchy instead of divider structure',
    (tester) async {
      await tester.pumpWidget(buildTestApp(selectedIndex: 0));
      await tester.pumpAndSettle();

      expect(find.text('Canvas Format'), findsOneWidget);
      expect(find.text('Framing'), findsOneWidget);
      expect(find.text('Background'), findsOneWidget);
      expect(find.byType(AppSettingsGroup), findsNWidgets(3));
      expect(find.byType(Divider), findsNothing);
      expect(find.text('Pick an image'), findsOneWidget);
      expect(find.text('More colors'), findsOneWidget);
      expect(find.byKey(const Key('canvas_aspect_selector')), findsOneWidget);
      expect(find.byKey(PlatformDropdown.fieldKey), findsOneWidget);
    },
  );

  testWidgets('canvas tab renders resolution dropdown and fires callback', (
    tester,
  ) async {
    ResolutionPreset? selectedPreset;

    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 0,
        onResolutionPresetChanged: (preset) => selectedPreset = preset,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Resolution'), findsOneWidget);
    expect(find.text('Auto'), findsWidgets);

    await tester.tap(find.byKey(PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1440p (2K)').last);
    await tester.pumpAndSettle();

    expect(selectedPreset, ResolutionPreset.p1440);
  });

  testWidgets('canvas tab taps canvas aspect card callback', (tester) async {
    LayoutPreset? selectedPreset;

    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 0,
        onLayoutPresetChanged: (preset) => selectedPreset = preset,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('canvas_aspect_option_youtube169')),
    );
    await tester.pumpAndSettle();

    expect(selectedPreset, LayoutPreset.youtube169);
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
        selectedIndex: 0,
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

  testWidgets('camera tab shows visibility only when camera asset is missing', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(selectedIndex: 1, hasCameraAsset: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('Visibility'), findsOneWidget);
    expect(find.text('Placement'), findsNothing);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Motion'), findsNothing);
    expect(
      find.text('No separate camera asset was recorded for this clip.'),
      findsOneWidget,
    );
  });

  testWidgets('camera tab shows full hierarchy when camera is visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        hasCameraAsset: true,
        cameraState: const CameraCompositionState.hidden().copyWith(
          visible: true,
          layoutPreset: CameraLayoutPreset.overlayBottomRight,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Visibility'), findsOneWidget);
    expect(find.text('Placement'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Motion'), findsOneWidget);
    expect(find.byType(AppSettingsGroup), findsNWidgets(4));
  });

  testWidgets('camera tab omits advanced groups when camera is hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        hasCameraAsset: true,
        cameraState: const CameraCompositionState.hidden().copyWith(
          visible: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Visibility'), findsOneWidget);
    expect(find.text('Placement'), findsNothing);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Motion'), findsNothing);
  });

  testWidgets('camera section uses position panel and no deprecated fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        hasCameraAsset: true,
        cameraState: const CameraCompositionState.hidden().copyWith(
          visible: true,
          layoutPreset: CameraLayoutPreset.overlayBottomRight,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('camera_position_panel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('camera_position_preset_overlayBottomRight')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('camera_position_handle')),
      findsOneWidget,
    );
    expect(find.text('Custom Position X'), findsNothing);
    expect(find.text('Custom Position Y'), findsNothing);
    expect(find.text('Reset manual position'), findsNothing);
  });

  testWidgets('camera position panel taps preset callback', (tester) async {
    CameraLayoutPreset? selectedPreset;

    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        hasCameraAsset: true,
        cameraState: const CameraCompositionState.hidden().copyWith(
          visible: true,
          layoutPreset: CameraLayoutPreset.overlayBottomRight,
        ),
        onCameraLayoutPresetChanged: (preset) => selectedPreset = preset,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('camera_position_preset_overlayTopLeft')),
    );
    await tester.pumpAndSettle();

    expect(selectedPreset, CameraLayoutPreset.overlayTopLeft);
  });

  testWidgets('camera position panel drag emits manual center callbacks', (
    tester,
  ) async {
    final changedCenters = <Offset>[];
    final endedCenters = <Offset>[];

    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        hasCameraAsset: true,
        cameraState: const CameraCompositionState.hidden().copyWith(
          visible: true,
          layoutPreset: CameraLayoutPreset.overlayBottomRight,
          normalizedCanvasCenter: const Offset(0.5, 0.5),
        ),
        onCameraManualCenterChanged: changedCenters.add,
        onCameraManualCenterChangeEnd: endedCenters.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('camera_position_handle')),
      const Offset(-48, -32),
    );
    await tester.pumpAndSettle();

    expect(changedCenters, isNotEmpty);
    expect(endedCenters, isNotEmpty);
    expect(endedCenters.last.dx, lessThan(0.5));
    expect(endedCenters.last.dy, lessThan(0.5));
    expect(endedCenters.last.dx, greaterThanOrEqualTo(0.0));
    expect(endedCenters.last.dy, greaterThanOrEqualTo(0.0));
  });

  testWidgets('camera motion uses inset groups for dependent controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 1,
        hasCameraAsset: true,
        cameraState: const CameraCompositionState.hidden().copyWith(
          visible: true,
          layoutPreset: CameraLayoutPreset.overlayBottomRight,
          zoomBehavior: CameraZoomBehavior.scaleWithScreenZoom,
          zoomScaleMultiplier: 0.35,
          introPreset: CameraIntroPreset.pop,
          outroPreset: CameraOutroPreset.fade,
          zoomEmphasisPreset: CameraZoomEmphasisPreset.pulse,
          introDurationMs: 300,
          outroDurationMs: 260,
          zoomEmphasisStrength: 0.12,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Zoom Scale'), findsOneWidget);
    expect(find.text('Intro Duration'), findsOneWidget);
    expect(find.text('Outro Duration'), findsOneWidget);
    expect(find.text('Pulse Strength'), findsOneWidget);
    expect(find.byType(AppInsetGroup), findsAtLeastNWidgets(4));
  });

  testWidgets('effects tab shows cursor and zoom groups without audio', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 2,
        cursorAvailable: false,
        hasAudio: false,
        showCursor: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cursor'), findsOneWidget);
    expect(find.text('Zoom'), findsOneWidget);
    expect(find.text('Audio'), findsNothing);
    expect(find.byType(AppInlineNotice), findsOneWidget);
    expect(find.text('Cursor data missing'), findsOneWidget);
    expect(find.text('No mic audio track found'), findsNothing);
  });

  testWidgets('effects tab uses inset groups for cursor and zoom reveals', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(selectedIndex: 2, showCursor: true, zoomFactor: 2.0),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('post_cursor_size_gap')), findsOneWidget);
    expect(find.byKey(const Key('post_zoom_intensity_gap')), findsOneWidget);
    expect(find.byType(AppInsetGroup), findsNWidgets(2));
  });

  testWidgets('effects tab exposes zoom and cursor helper copy as tooltips', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 2));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Toggle cursor visibility'), findsOneWidget);
    expect(find.text('Toggle cursor visibility'), findsNothing);
    expect(find.byTooltip('Manage zoom in effects'), findsOneWidget);
    expect(find.text('Manage zoom in effects'), findsNothing);
  });

  testWidgets('zoom toggle preserves enable and disable callback behavior', (
    tester,
  ) async {
    final changed = <double>[];
    final ended = <double>[];

    await tester.pumpWidget(
      buildTestApp(
        selectedIndex: 2,
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
        selectedIndex: 2,
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

  testWidgets('export tab shows audio and loudness groups', (tester) async {
    await tester.pumpWidget(
      buildTestApp(selectedIndex: 3, autoNormalizeOnExport: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Loudness'), findsOneWidget);
    expect(find.text('Format'), findsNothing);
    expect(find.text('Codec'), findsNothing);
    expect(find.text('Bitrate'), findsNothing);
    expect(find.text('Auto-normalize on export'), findsOneWidget);
    expect(find.text('Target loudness'), findsNothing);

    await tester.pumpWidget(
      buildTestApp(selectedIndex: 3, autoNormalizeOnExport: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Target loudness'), findsOneWidget);
    expect(find.byType(AppInsetGroup), findsOneWidget);
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
    await expectGap(3);
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
    expect(blockedIgnorePointer, findsAtLeastNWidgets(1));
  });

  testWidgets('background color picker dialog opens without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp(selectedIndex: 0));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('More colors'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More colors'));
    await tester.pumpAndSettle();

    expect(find.byType(ColorPicker), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
