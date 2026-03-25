import 'package:clingfy/app/home/recording/widgets/recording_options_sidebar.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestApp() {
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

  testWidgets('dark sidebar uses the shared rail chrome and selected tile', (
    tester,
  ) async {
    final theme = buildDarkTheme();

    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    final railFinder = find.byKey(const Key('recording_sidebar_rail'));
    final rail = tester.widget<Container>(railFinder);
    final selectedTileDecoration = _decorationFor(
      tester,
      find.byKey(const ValueKey('recording_sidebar_rail_tile_0')),
    );

    expect(
      tester.getSize(railFinder).width,
      theme.appEditorChrome.editorRailWidth,
    );
    expect(
      rail.color,
      Color.alphaBlend(
        theme.inputDecorationTheme.fillColor!.withValues(alpha: 0.18),
        theme.colorScheme.surface,
      ),
    );
    expect(find.byKey(const Key('recording_sidebar_header')), findsOneWidget);
    expect(
      selectedTileDecoration.color,
      theme.colorScheme.primary.withValues(alpha: 0.16),
    );
    expect(
      selectedTileDecoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.controlRadius + 2),
    );
  });
}

BoxDecoration _decorationFor(WidgetTester tester, Finder finder) {
  final container = tester.widget<Container>(finder);
  return container.decoration! as BoxDecoration;
}
