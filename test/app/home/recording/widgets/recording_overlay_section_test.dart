import 'package:clingfy/app/home/recording/widgets/recording_overlay_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:macos_ui/macos_ui.dart';

Widget _buildSection({
  bool isRecording = false,
  OverlayShape overlayShape = OverlayShape.squircle,
  OverlayMode overlayMode = OverlayMode.alwaysOn,
  OverlayPosition overlayPosition = OverlayPosition.bottomRight,
  bool overlayUseCustomPosition = false,
  double overlayRoundness = 0.2,
  OverlayBorder overlayBorder = OverlayBorder.none,
  bool overlayRecordingHighlightEnabled = false,
  bool chromaKeyEnabled = false,
  ValueChanged<OverlayPosition>? onOverlayPositionChanged,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MacosTheme(
      data: MacosThemeData.light(),
      child: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 720,
              child: RecordingOverlaySection(
                isRecording: isRecording,
                overlayMode: overlayMode,
                overlayShape: overlayShape,
                overlaySize: 220,
                overlayShadow: OverlayShadow.none,
                overlayBorder: overlayBorder,
                overlayPosition: overlayPosition,
                overlayUseCustomPosition: overlayUseCustomPosition,
                overlayRoundness: overlayRoundness,
                overlayOpacity: 1.0,
                overlayMirror: true,
                overlayRecordingHighlightEnabled:
                    overlayRecordingHighlightEnabled,
                overlayRecordingHighlightStrength: 0.7,
                overlayBorderWidth: 4.0,
                overlayBorderColor: 0xFFFFFFFF,
                chromaKeyEnabled: chromaKeyEnabled,
                chromaKeyStrength: 0.4,
                chromaKeyColor: 0xFF00FF00,
                onOverlayModeChanged: (_) {},
                onOverlayShapeChanged: (_) {},
                onOverlaySizeChanged: (_) {},
                onOverlayShadowChanged: (_) {},
                onOverlayBorderChanged: (_) {},
                onOverlayPositionChanged: onOverlayPositionChanged ?? (_) {},
                onOverlayRoundnessChanged: (_) {},
                onOverlayOpacityChanged: (_) {},
                onOverlayMirrorChanged: (_) {},
                onOverlayRecordingHighlightEnabledChanged: (_) {},
                onOverlayRecordingHighlightStrengthChanged: (_) {},
                onOverlayBorderWidthChanged: (_) {},
                onOverlayBorderColorChanged: (_) {},
                onChromaKeyEnabledChanged: (_) {},
                onChromaKeyStrengthChanged: (_) {},
                onChromaKeyColorChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('overlay settings use explicit top-level groups', (tester) async {
    await tester.pumpWidget(_buildSection());
    await tester.pumpAndSettle();

    expect(find.byType(AppSettingsGroup), findsNWidgets(4));
    expect(find.text('Visibility & Placement'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Style'), findsOneWidget);
    expect(find.text('Effects'), findsOneWidget);
  });

  testWidgets('overlay mode off keeps only visibility and placement visible', (
    tester,
  ) async {
    await tester.pumpWidget(_buildSection(overlayMode: OverlayMode.off));
    await tester.pumpAndSettle();

    expect(find.text('Visibility & Placement'), findsOneWidget);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Style'), findsNothing);
    expect(find.text('Effects'), findsNothing);
  });

  testWidgets('shape dropdown shows squircle first with localized label', (
    tester,
  ) async {
    await tester.pumpWidget(_buildSection());

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOverlaySection)),
    )!;
    final dropdown = tester.widget<PlatformDropdown<OverlayShape>>(
      find.byWidgetPredicate(
        (widget) => widget is PlatformDropdown<OverlayShape>,
      ),
    );

    expect(
      dropdown.items.map((item) => item.value).toList(),
      equals(OverlayShape.uiChoices),
    );
    expect(dropdown.items.first.label, l10n.squircle);
  });

  testWidgets(
    'sidebar dropdown fields fill the available control width by default',
    (tester) async {
      await tester.pumpWidget(_buildSection());
      await tester.pumpAndSettle();

      final shapeField = find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is PlatformDropdown<OverlayShape>,
        ),
        matching: find.byKey(PlatformDropdown.fieldKey),
      );

      expect(
        tester.getSize(shapeField).width,
        moreOrLessEquals(
          720 - AppSidebarTokens.labelWidth - AppSidebarTokens.controlGap,
        ),
      );
    },
  );

  testWidgets(
    'custom position badge exposes tooltip helper when custom mode is on',
    (tester) async {
      await tester.pumpWidget(_buildSection(overlayUseCustomPosition: true));

      final l10n = AppLocalizations.of(
        tester.element(find.byType(RecordingOverlaySection)),
      )!;
      final context = tester.element(find.byType(RecordingOverlaySection));
      final theme = Theme.of(context);

      expect(
        find.byKey(const Key('overlay_custom_position_badge')),
        findsOneWidget,
      );
      expect(find.text(l10n.customPosition), findsOneWidget);
      expect(find.byTooltip(l10n.customPositionHint), findsOneWidget);
      expect(find.text(l10n.customPositionHint), findsNothing);

      for (final key in const [
        ValueKey('overlay_position_topLeft'),
        ValueKey('overlay_position_topRight'),
        ValueKey('overlay_position_bottomLeft'),
        ValueKey('overlay_position_bottomRight'),
      ]) {
        final container = tester.widget<Container>(find.byKey(key));
        final decoration = container.decoration! as BoxDecoration;
        final border = decoration.border! as Border;
        expect(border.top.color, isNot(theme.primaryColor));
      }
    },
  );

  testWidgets('overlay helper copy is exposed via inline tooltips', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildSection(
        overlayMode: OverlayMode.whileRecording,
        overlayUseCustomPosition: true,
        chromaKeyEnabled: true,
      ),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOverlaySection)),
    )!;

    expect(find.byTooltip(l10n.overlayHint), findsOneWidget);
    expect(find.text(l10n.overlayHint), findsNothing);
    expect(find.byTooltip(l10n.customPositionHint), findsOneWidget);
    expect(find.text(l10n.customPositionHint), findsNothing);
    expect(find.byTooltip(l10n.targetColorToRemove), findsOneWidget);
    expect(find.text(l10n.targetColorToRemove), findsNothing);
    expect(
      find.ancestor(
        of: find.text(l10n.keyTolerance('40')),
        matching: find.byType(AppInsetGroup),
      ),
      findsOneWidget,
    );
  });

  testWidgets('overlay hint tooltip hides once recording is active', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildSection(overlayMode: OverlayMode.whileRecording),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOverlaySection)),
    )!;

    expect(find.byTooltip(l10n.overlayHint), findsOneWidget);

    await tester.pumpWidget(
      _buildSection(isRecording: true, overlayMode: OverlayMode.whileRecording),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip(l10n.overlayHint), findsNothing);
  });

  testWidgets('tapping a preset position still triggers the callback', (
    tester,
  ) async {
    OverlayPosition? selectedPosition;

    await tester.pumpWidget(
      _buildSection(
        overlayUseCustomPosition: true,
        onOverlayPositionChanged: (position) {
          selectedPosition = position;
        },
      ),
    );

    await tester.tap(find.byKey(const ValueKey('overlay_position_topLeft')));
    await tester.pump();

    expect(selectedPosition, OverlayPosition.topLeft);
  });

  testWidgets('squircle does not show roundness slider', (tester) async {
    await tester.pumpWidget(
      _buildSection(overlayShape: OverlayShape.squircle, overlayRoundness: 0.2),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOverlaySection)),
    )!;

    expect(find.text(l10n.cornerRoundness('20')), findsNothing);
  });

  testWidgets('rounded rectangle still shows roundness slider', (tester) async {
    await tester.pumpWidget(
      _buildSection(
        overlayShape: OverlayShape.roundedRect,
        overlayRoundness: 0.2,
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOverlaySection)),
    )!;

    expect(find.text(l10n.cornerRoundness('20')), findsOneWidget);
  });

  testWidgets('recording highlight reveals a subordinate inset group', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildSection(overlayRecordingHighlightEnabled: true),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOverlaySection)),
    )!;

    expect(find.text(l10n.recordingGlowStrengthPercent('70')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(l10n.recordingGlowStrengthPercent('70')),
        matching: find.byType(AppInsetGroup),
      ),
      findsOneWidget,
    );
  });

  testWidgets('border details reveal inside an inset group when enabled', (
    tester,
  ) async {
    await tester.pumpWidget(_buildSection(overlayBorder: OverlayBorder.white));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingOverlaySection)),
    )!;

    expect(find.text('More colors'), findsOneWidget);
    expect(find.text(l10n.borderWidth('4.0')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(l10n.borderWidth('4.0')),
        matching: find.byType(AppInsetGroup),
      ),
      findsOneWidget,
    );
  });

  testWidgets('border color picker dialog opens without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(_buildSection(overlayBorder: OverlayBorder.white));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('More colors'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More colors'));
    await tester.pumpAndSettle();

    expect(find.byType(ColorPicker), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
