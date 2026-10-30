import 'package:clingfy/app/home/export/widgets/export_file_dialog.dart';
import 'package:clingfy/core/export/models/export_settings_types.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildDialog({
    ExportFormat initialExportFormat = ExportFormat.mov,
    GifSizePreset initialGifSize = GifSizePreset.large,
    AudioQuality initialAudioQuality = AudioQuality.standard,
    int? exportDurationMs,
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
          body: ExportFileDialog(
            initialFileName: 'Clingfy Export',
            initialDirectory: '/tmp',
            initialResolutionPreset: ResolutionPreset.auto,
            initialExportFormat: initialExportFormat,
            initialExportCodec: ExportCodec.hevc,
            initialExportBitrate: ExportBitratePreset.auto,
            initialGifSize: initialGifSize,
            initialAudioQuality: initialAudioQuality,
            onPickFolder: () async => null,
            exportDurationMs: exportDurationMs,
          ),
        ),
      ),
    );
  }

  VoidCallback? exportPressed(WidgetTester tester) =>
      tester.widget<AppButton>(find.byKey(exportButtonKey)).onPressed;

  group('GIF length cap', () {
    testWidgets('a GIF past the cap is refused, with the reason', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildDialog(
          initialExportFormat: ExportFormat.gif,
          exportDurationMs: 102000,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(gifTooLongKey), findsOneWidget);
      expect(find.textContaining('at most 60 seconds'), findsOneWidget);
      expect(find.textContaining('1:42'), findsOneWidget);
      expect(exportPressed(tester), isNull, reason: 'Export is disabled');

      // Enter in the name field submits without the button.
      await tester.tap(find.byType(TextField).first);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.byType(ExportFileDialog),
        findsOneWidget,
        reason: 'not closed',
      );
    });

    testWidgets('exactly the cap exports', (tester) async {
      await tester.pumpWidget(
        buildDialog(
          initialExportFormat: ExportFormat.gif,
          exportDurationMs: kGifMaxExportDurationMs,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(gifTooLongKey), findsNothing);
      expect(exportPressed(tester), isNotNull);
    });

    testWidgets('only GIF is capped', (tester) async {
      await tester.pumpWidget(
        buildDialog(
          initialExportFormat: ExportFormat.mp4,
          exportDurationMs: 600000,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(gifTooLongKey), findsNothing);
      expect(exportPressed(tester), isNotNull);
    });

    testWidgets('an unknown length is left to the exporter', (tester) async {
      await tester.pumpWidget(
        buildDialog(initialExportFormat: ExportFormat.gif),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(gifTooLongKey), findsNothing);
      expect(exportPressed(tester), isNotNull);
    });
  });

  testWidgets('format dropdown includes mov gif and mp4', (tester) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    final formatDropdown = tester.widget<PlatformDropdown<ExportFormat>>(
      find.byWidgetPredicate(
        (widget) => widget is PlatformDropdown<ExportFormat>,
      ),
    );

    expect(formatDropdown.items.map((item) => item.label).toList(), [
      '.mov',
      '.gif',
      '.mp4',
    ]);
  });

  testWidgets(
    'gif format hides resolution/codec/bitrate and shows the Size control',
    (tester) async {
      await tester.pumpWidget(
        buildDialog(initialExportFormat: ExportFormat.gif),
      );
      await tester.pumpAndSettle();

      // Video-encoding controls do not apply to GIF.
      expect(find.text('Resolution'), findsNothing);
      expect(find.text('Codec'), findsNothing);
      expect(find.text('Bitrate'), findsNothing);

      // GIF gets a single Small/Medium/Large size control instead.
      expect(find.text('Size'), findsOneWidget);
      final sizeDropdown = tester.widget<PlatformDropdown<GifSizePreset>>(
        find.byWidgetPredicate(
          (widget) => widget is PlatformDropdown<GifSizePreset>,
        ),
      );
      expect(sizeDropdown.items.map((item) => item.value).toList(), const [
        GifSizePreset.small,
        GifSizePreset.medium,
        GifSizePreset.large,
      ]);
    },
  );

  testWidgets(
    'switching format to gif swaps video controls for the Size control',
    (tester) async {
      await tester.pumpWidget(
        buildDialog(initialExportFormat: ExportFormat.mov),
      );
      await tester.pumpAndSettle();

      expect(find.text('Resolution'), findsOneWidget);
      expect(find.text('Codec'), findsOneWidget);
      expect(find.text('Bitrate'), findsOneWidget);
      expect(find.text('Size'), findsNothing);

      final formatDropdown = tester.widget<PlatformDropdown<ExportFormat>>(
        find.byWidgetPredicate(
          (widget) => widget is PlatformDropdown<ExportFormat>,
        ),
      );
      formatDropdown.onChanged?.call(ExportFormat.gif);
      await tester.pumpAndSettle();

      expect(find.text('Resolution'), findsNothing);
      expect(find.text('Codec'), findsNothing);
      expect(find.text('Bitrate'), findsNothing);
      expect(find.text('Size'), findsOneWidget);
    },
  );

  testWidgets('export returns the chosen GIF size in the result', (
    tester,
  ) async {
    ExportFileDialogResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        home: MacosTheme(
          data: buildMacosTheme(Brightness.dark),
          child: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await ExportFileDialog.show(
                    context,
                    initialFileName: 'Clingfy Export',
                    initialDirectory: '/tmp',
                    initialResolutionPreset: ResolutionPreset.auto,
                    initialExportFormat: ExportFormat.gif,
                    initialExportCodec: ExportCodec.hevc,
                    initialExportBitrate: ExportBitratePreset.auto,
                    initialGifSize: GifSizePreset.large,
                    initialAudioQuality: AudioQuality.standard,
                    onPickFolder: () async => null,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Pick Small, then Export.
    final sizeDropdown = tester.widget<PlatformDropdown<GifSizePreset>>(
      find.byWidgetPredicate(
        (widget) => widget is PlatformDropdown<GifSizePreset>,
      ),
    );
    sizeDropdown.onChanged?.call(GifSizePreset.small);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.exportFormat, ExportFormat.gif);
    expect(captured!.gifSize, GifSizePreset.small);
  });

  testWidgets('uses close icon in header instead of footer cancel button', (
    tester,
  ) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('export_file_dialog_close_button')),
      findsOneWidget,
    );
    expect(find.byType(AppIconButton), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Export'), findsOneWidget);
  });

  testWidgets('fixed-width export format dropdown keeps its authored width', (
    tester,
  ) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    final formatField = find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is PlatformDropdown<ExportFormat>,
      ),
      matching: find.byKey(PlatformDropdown.fieldKey),
    );

    expect(tester.getSize(formatField).width, moreOrLessEquals(100));
  });

  testWidgets('dialog background matches desktop toolbar background', (
    tester,
  ) async {
    final expectedBackground = buildDarkTheme()
        .extension<AppThemeTokens>()!
        .editorChromeBackground;

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    final dialogMaterial = tester.widget<Material>(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.card,
        ),
      ),
    );

    expect(dialogMaterial.color, expectedBackground);
  });

  // ---- Audio quality ----------------------------------------------------
  //
  // Both shipped platforms offer the three tiers. Windows used to hide the
  // picker because every tier resolved to 192 kbps; the Media Foundation AAC
  // encoder has since been measured producing 256 and 320 kbps
  // (windows/runner_tests/aac_encoder_bitrate_test.cpp), and the export steps
  // down where an older encoder refuses. The platform is pinned rather than
  // inherited from the host so each branch is asserted deliberately.

  tearDown(() => debugPlatformKindOverride = null);

  testWidgets('macOS offers the three tiers, labelled with their bitrates', (
    tester,
  ) async {
    debugPlatformKindOverride = PlatformKind.macos;
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    expect(find.text('Audio quality'), findsOneWidget);
    final dropdown = tester.widget<PlatformDropdown<AudioQuality>>(
      find.byWidgetPredicate(
        (widget) => widget is PlatformDropdown<AudioQuality>,
      ),
    );
    // The kbps in each label comes off AudioQuality.targetKbps, so a label
    // that disagrees with the native ceiling fails here rather than shipping.
    expect(dropdown.items.map((i) => i.label).toList(), [
      'Standard (192 kbps)',
      'High (256 kbps)',
      'Best (320 kbps)',
    ]);
    expect(dropdown.value, AudioQuality.standard);
  });

  testWidgets('Windows offers the same three tiers', (tester) async {
    debugPlatformKindOverride = PlatformKind.windows;
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    expect(find.text('Audio quality'), findsOneWidget);
    final dropdown = tester.widget<PlatformDropdown<AudioQuality>>(
      find.byWidgetPredicate((w) => w is PlatformDropdown<AudioQuality>),
    );
    expect(dropdown.items.map((i) => i.label).toList(), [
      'Standard (192 kbps)',
      'High (256 kbps)',
      'Best (320 kbps)',
    ]);
    expect(find.text('Bitrate'), findsOneWidget);
  });

  testWidgets('GIF hides it on Windows too', (tester) async {
    debugPlatformKindOverride = PlatformKind.windows;
    await tester.pumpWidget(buildDialog(initialExportFormat: ExportFormat.gif));
    await tester.pumpAndSettle();

    expect(find.text('Audio quality'), findsNothing);
  });

  testWidgets('GIF hides it on macOS too, because GIF has no audio track', (
    tester,
  ) async {
    debugPlatformKindOverride = PlatformKind.macos;
    await tester.pumpWidget(buildDialog(initialExportFormat: ExportFormat.gif));
    await tester.pumpAndSettle();

    expect(find.text('Audio quality'), findsNothing);
    expect(find.text('Size'), findsOneWidget, reason: 'the GIF control shows');
  });

  testWidgets('the chosen tier comes back in the result', (tester) async {
    debugPlatformKindOverride = PlatformKind.macos;
    await tester.pumpWidget(
      buildDialog(initialAudioQuality: AudioQuality.best),
    );
    await tester.pumpAndSettle();

    final dropdown = tester.widget<PlatformDropdown<AudioQuality>>(
      find.byWidgetPredicate((w) => w is PlatformDropdown<AudioQuality>),
    );
    expect(
      dropdown.value,
      AudioQuality.best,
      reason: 'the dialog must open on the stored preference, not the default',
    );
  });
}
