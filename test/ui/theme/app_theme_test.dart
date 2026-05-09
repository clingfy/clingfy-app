import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('material themes keep the Clingfy brand accent across modes', () {
    final lightTheme = buildLightTheme();
    final darkTheme = buildDarkTheme();

    expect(lightTheme.colorScheme.primary, clingfyBrandColor);
    expect(darkTheme.colorScheme.primary, clingfyBrandColor);
    expect(lightTheme.appTokens.brand, clingfyBrandColor);
    expect(darkTheme.appTokens.brand, clingfyBrandColor);
    expect(
      lightTheme.appTokens.panelBackground,
      isNot(darkTheme.appTokens.panelBackground),
    );
    expect(lightTheme.appTokens.shellGradient.colors, isNotEmpty);
    expect(darkTheme.appTokens.shellGradient.colors, const [
      Color(0xFF05070B),
      Color(0xFF05070B),
    ]);
    expect(darkTheme.scaffoldBackgroundColor, const Color(0xFF05070B));
    expect(darkTheme.canvasColor, const Color(0xFF0E1318));
    expect(darkTheme.cardColor, const Color(0xFF0E1318));
    expect(darkTheme.colorScheme.surface, const Color(0xFF0E1318));
    expect(
      darkTheme.colorScheme.surfaceContainerHighest,
      const Color(0xFF0E1318),
    );
    expect(darkTheme.appTokens.outerBackground, const Color(0xFF05070B));
    expect(darkTheme.appTokens.panelBackground, const Color(0xFF0E1318));
    expect(darkTheme.appTokens.editorChromeBackground, const Color(0xFF15161A));
    expect(darkTheme.appTokens.previewPanelBackground, const Color(0xFF151718));
    expect(darkTheme.appTokens.timelineBackground, const Color(0xFF111113));
    expect(darkTheme.appTokens.timelineChromeSurface, const Color(0xFF1A1B20));
    expect(
      darkTheme.appTokens.timelineViewportSurface,
      const Color(0xFF16181C),
    );
    expect(
      darkTheme.appTokens.timelineTrackHeaderSurface,
      const Color(0xFF18191E),
    );
    expect(darkTheme.appTokens.timelineLaneSurface, const Color(0xFF1C1D22));
    expect(darkTheme.inputDecorationTheme.fillColor, const Color(0xFF2A2D35));
    expect(
      darkTheme.appTokens.timelineChromeSurface,
      isNot(darkTheme.inputDecorationTheme.fillColor),
    );
    expect(
      darkTheme.appTokens.timelineLaneSurface,
      isNot(darkTheme.inputDecorationTheme.fillColor),
    );
    expect(
      darkTheme.dropdownMenuTheme.inputDecorationTheme?.fillColor,
      const Color(0xFF2A2D35),
    );
    expect(darkTheme.sliderTheme.inactiveTrackColor, const Color(0xFF2A2D35));
    expect(darkTheme.sliderTheme.thumbColor, Colors.white);
    expect(
      (darkTheme.sliderTheme.thumbShape as RoundSliderThumbShape)
          .enabledThumbRadius,
      5,
    );
  });

  test('semantic spacing and typography tokens are available and stable', () {
    final lightTheme = buildLightTheme();
    final darkTheme = buildDarkTheme();

    expect(lightTheme.appSpacing.xs, 4);
    expect(lightTheme.appSpacing.sm, 8);
    expect(lightTheme.appSpacing.md, 12);
    expect(lightTheme.appSpacing.lg, 16);
    expect(lightTheme.appSpacing.xl, 20);
    expect(lightTheme.appSpacing.xxl, 24);
    expect(lightTheme.appSpacing.page, 16);
    expect(lightTheme.appSpacing.panel, 20);
    expect(lightTheme.appSpacing.dialog, 24);

    expect(lightTheme.appTypography.pageTitle.fontSize, 22);
    expect(lightTheme.appTypography.pageTitle.fontWeight, FontWeight.w700);
    expect(lightTheme.appTypography.panelTitle.fontSize, 18);
    expect(lightTheme.appTypography.sectionEyebrow.letterSpacing, 1.1);
    expect(lightTheme.appTypography.rowLabel.fontSize, 13);
    expect(lightTheme.appTypography.body.fontSize, 13);
    expect(lightTheme.appTypography.body.height, 1.35);
    expect(lightTheme.appTypography.bodyMuted.fontSize, 12);
    expect(lightTheme.appTypography.value.fontSize, 12);
    expect(lightTheme.appTypography.button.fontSize, 13);
    expect(lightTheme.appTypography.caption.fontSize, 11);
    expect(lightTheme.appTypography.mono.fontFamily, 'monospace');

    expect(
      darkTheme.appTypography.pageTitle.color,
      isNot(lightTheme.appTypography.pageTitle.color),
    );
    expect(darkTheme.appSpacing.dialog, lightTheme.appSpacing.dialog);
  });

  test('editor chrome tokens expose the workstation shell defaults', () {
    final darkTheme = buildDarkTheme();
    final chrome = darkTheme.appEditorChrome;

    expect(kEditorShellOuterPadding, 2);
    expect(kEditorShellInnerPadding, 6);
    expect(kEditorShellGap, 4);
    expect(chrome.shellRadius, 11);
    expect(chrome.panelRadius, 9);
    expect(chrome.controlRadius, 6);
    expect(chrome.pillRadius, 999);
    expect(chrome.toolbarHeight, 50);
    expect(chrome.editorRailWidth, 60);
    expect(chrome.stagePadding, 8);
    expect(chrome.compactControlHeight, 32);
    expect(chrome.inspectorTabHeight, 34);
    // expect(chrome.timelineRulerHeight, 70);
    expect(chrome.timelineLaneHeight, 42);
    expect(chrome.timelineTrackHeaderWidth, 92);
    expect(chrome.timelineHorizontalPadding, 12);
    expect(chrome.timelineVerticalPadding, 10);
  });

  test('platform themes derive from the same semantic palette', () {
    final lightTheme = buildLightTheme();
    final darkTheme = buildDarkTheme();
    final macosTheme = buildMacosTheme(Brightness.dark);
    final fluentTheme = buildFluentTheme(Brightness.light);
    final fluentDarkTheme = buildFluentTheme(Brightness.dark);

    expect(macosTheme.primaryColor, clingfyBrandColor);
    expect(macosTheme.canvasColor, darkTheme.appTokens.panelBackground);
    expect(macosTheme.dividerColor, darkTheme.appTokens.panelBorder);
    expect(
      macosTheme.popupButtonTheme.backgroundColor,
      const Color(0xFF2A2D35),
    );
    expect(macosTheme.popupButtonTheme.popupColor, const Color(0xFF0E1318));
    expect(
      macosTheme.pulldownButtonTheme.backgroundColor,
      const Color(0xFF2A2D35),
    );
    expect(
      macosTheme.pulldownButtonTheme.pulldownColor,
      const Color(0xFF0E1318),
    );

    expect(fluentTheme.accentColor, isA<fluent.AccentColor>());
    expect(fluentTheme.accentColor.normal, clingfyBrandColor);
    expect(
      fluentTheme.scaffoldBackgroundColor,
      lightTheme.scaffoldBackgroundColor,
    );
    expect(
      fluentTheme.selectionColor,
      fluentTheme.accentColor.defaultBrushFor(Brightness.light),
    );
    expect(fluentDarkTheme.scaffoldBackgroundColor, const Color(0xFF05070B));
    expect(fluentDarkTheme.cardColor, const Color(0xFF0E1318));
    expect(fluentDarkTheme.menuColor, const Color(0xFF0E1318));
    expect(fluentDarkTheme.inactiveBackgroundColor, const Color(0xFF2A2D35));
  });
}
