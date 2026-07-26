import 'package:clingfy/app/home/post_processing/widgets/post_background_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_output_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_source_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

/// Phase 10.3 honest-UI sweep: controls whose native half is a no-op on
/// Windows are hidden there — and stay visible on macOS where they work.
/// Covered here (standalone sections):
///   - RecordingOutputSection: frame-rate group (setCaptureFrameRate no-op)
///   - RecordingSourceSection: area Reveal button (reveal overlay missing)
///   - PostBackgroundSection: image/preset modes (export renders color only)
void main() {
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  Widget host(Widget child) {
    return MaterialApp(
      localizationsDelegates: const [
        ...AppLocalizations.localizationsDelegates,
        fluent.FluentLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // Platform widgets render fluent variants under the Windows override
      // and macos variants under the macOS override — provide both theme
      // ancestors so either branch can build.
      builder: (context, c) => fluent.FluentTheme(
        data: fluent.FluentThemeData(),
        child: MacosTheme(data: MacosThemeData.light(), child: c!),
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
  }

  group('RecordingOutputSection frame-rate group', () {
    Widget section() => RecordingOutputSection(
      isRecording: false,
      captureFrameRate: 30,
      autoStopEnabled: false,
      autoStopAfter: const Duration(minutes: 5),
      countdownEnabled: false,
      countdownDuration: 3,
      onFrameRateChanged: (_) {},
      onAutoStopEnabledChanged: (_) {},
      onAutoStopAfterChanged: (_) {},
      onCountdownEnabledChanged: (_) {},
      onCountdownDurationChanged: (_) {},
    );

    testWidgets('hidden on Windows (setCaptureFrameRate is a no-op)', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(host(section()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('recording_output_quality_group')),
        findsNothing,
      );
      // The rest of the section still renders.
      expect(
        find.byKey(const Key('recording_output_start_stop_group')),
        findsOneWidget,
      );
    });

    testWidgets('visible on macOS', (tester) async {
      debugPlatformKindOverride = PlatformKind.macos;
      await tester.pumpWidget(host(section()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('recording_output_quality_group')),
        findsOneWidget,
      );
    });
  });

  group('RecordingSourceSection area Reveal button', () {
    Widget section() => RecordingSourceSection(
      isRecording: false,
      targetMode: DisplayTargetMode.areaRecording,
      displays: const [],
      selectedDisplayId: null,
      appWindows: const [],
      selectedAppWindowId: null,
      areaDisplayId: 1,
      areaRect: const Rect.fromLTWH(10, 20, 300, 200),
      onTargetModeChanged: (_) {},
      onDisplayChanged: (_) {},
      onRefreshDisplays: () {},
      onAppWindowChanged: (_) {},
      onRefreshAppWindows: () {},
      onPickArea: () {},
      onRevealArea: () {},
      onClearArea: () {},
    );

    testWidgets('hidden on Windows (no reveal overlay exists)', (tester) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(host(section()));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      // Change/clear remain — only the no-op affordance is gone.
      expect(find.byIcon(Icons.crop_free), findsOneWidget);
      expect(find.byIcon(Icons.clear), findsOneWidget);
    });

    testWidgets('visible on macOS', (tester) async {
      debugPlatformKindOverride = PlatformKind.macos;
      await tester.pumpWidget(host(section()));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    });
  });

  group('PostBackgroundSection image/preset modes', () {
    Widget section(BackgroundKind kind) => PostBackgroundSection(
      isProcessing: false,
      backgroundColor: 0xFF4CAF50,
      backgroundImagePath: null,
      backgroundKind: kind,
      backgroundPreset: null,
      onBackgroundColorChanged: (_) {},
      onBackgroundImageChanged: (_) {},
      onBackgroundKindChanged: (_) {},
      onBackgroundPresetChanged: (_) {},
      onBackgroundPresetPreview: (_) {},
      onPickImage: () async => null,
    );

    testWidgets(
      'Windows: image segment is available and an image kind stays image',
      (tester) async {
        debugPlatformKindOverride = PlatformKind.windows;
        await tester.pumpWidget(host(section(BackgroundKind.image)));
        await tester.pumpAndSettle();
        // Canvas parity slice 2: Windows gained a real pickImage dialog, WIC
        // decode + cache, and compositing in BOTH the preview and the export,
        // so the image mode is no longer a silent no-op and is offered.
        //
        // TWO widgets carry this icon once image mode is active and selected:
        // the segment item, and the pick-image control beneath it. Before this
        // slice neither rendered on Windows, which is what the old expectation
        // of `findsNothing` encoded.
        expect(find.byIcon(Icons.image_outlined), findsNWidgets(2));
        // Procedural presets still need a renderer Windows does not have.
        expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
      },
    );

    testWidgets(
      'Windows: a stale preset kind is still displayed as color',
      (tester) async {
        debugPlatformKindOverride = PlatformKind.windows;
        // A project saved on macOS can persist kind=preset. Windows cannot
        // render it, so the DISPLAYED mode coerces to color and its controls
        // are live — rather than selecting a segment that is not offered.
        await tester.pumpWidget(host(section(BackgroundKind.preset)));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
        expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
      },
    );

    testWidgets('macOS: image and preset segments stay available', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.macos;
      await tester.pumpWidget(host(section(BackgroundKind.color)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    });
  });
}
