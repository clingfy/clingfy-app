import 'package:clingfy/app/home/post_processing/widgets/post_background_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_audio_section.dart';
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
///   - RecordingAudioSection: exclude-mic toggle — hidden for a DIFFERENT
///     reason than the rest of this file, so do not "fix" it by wiring the
///     setter up. The others are unbuilt; this one has nothing to build.
///     WASAPI takes system audio as loopback on the default render endpoint
///     and the mic on a separate capture endpoint, so the mic is never in the
///     system track. macOS needs the toggle because its aggregate device
///     really does mix them.
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
      onDisplayChanged: (_, _) {},
      onRefreshDisplays: () {},
      onIdentifyDisplays: (_) {},
      identifySupported: true,
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
        // Presets are offered on Windows too now — the segment renders even
        // while image mode is the active kind.
        expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
      },
    );

    testWidgets('Windows: a preset kind stays preset and its controls render', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.windows;
      // A preset kind used to be coerced to colour here, because Windows had no
      // renderer for it. Slice 3 gave it one — the same Direct2D renderer the
      // preview and the export share — so the stored kind is now what the user
      // sees, and the colour controls must NOT be what renders.
      await tester.pumpWidget(host(section(BackgroundKind.preset)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsNothing);
    });

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

  group('RecordingAudioSection exclude-mic toggle', () {
    // Both preconditions the toggle needs on macOS: system audio on AND a real
    // microphone selected. With either missing it is hidden on every platform,
    // so a passing Windows expectation would prove nothing.
    Widget section() => SizedBox(
      width: 720,
      child: RecordingAudioSection(
        isRecording: false,
        audioSources: const [
          AudioSource(id: 'mic-1', name: 'Built-in Microphone'),
        ],
        selectedAudioSourceId: 'mic-1',
        loadingAudio: false,
        systemAudioEnabled: true,
        systemAudioBleedRisk: false,
        excludeMicFromSystemAudio: false,
        micEchoCancellationEnabled: false,
        micInputLevelLinear: 0.0,
        micInputLevelDbfs: -160.0,
        micInputTooLow: false,
        onAudioSourceChanged: (_) {},
        onRefreshAudio: () {},
        onSystemAudioEnabledChanged: (_) {},
        onExcludeMicFromSystemAudioChanged: (_) {},
        onMicEchoCancellationEnabledChanged: (_) {},
      ),
    );

    String label(WidgetTester tester) {
      return AppLocalizations.of(
        tester.element(find.byType(RecordingAudioSection)),
      )!.recordingExcludeMicFromSystemAudio;
    }

    testWidgets('hidden on Windows (the mic is never in the system track)', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(host(section()));
      await tester.pumpAndSettle();
      expect(find.text(label(tester)), findsNothing);
      // The section itself still renders — this is one hidden row, not a
      // collapsed panel.
      expect(find.byType(RecordingAudioSection), findsOneWidget);
    });

    testWidgets('visible on macOS, where the aggregate device mixes them', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.macos;
      await tester.pumpWidget(host(section()));
      await tester.pumpAndSettle();
      expect(find.text(label(tester)), findsOneWidget);
    });
  });
}
