import 'dart:ui' show lerpDouble;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

const clingfyBrandColor = Color(0xFF8957E5);

@immutable
class AppToneColors {
  const AppToneColors({
    required this.background,
    required this.foreground,
    this.border,
  });

  final Color background;
  final Color foreground;
  final Color? border;

  AppToneColors copyWith({
    Color? background,
    Color? foreground,
    Color? border,
  }) {
    return AppToneColors(
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      border: border ?? this.border,
    );
  }

  static AppToneColors lerp(AppToneColors a, AppToneColors b, double t) {
    return AppToneColors(
      background: Color.lerp(a.background, b.background, t) ?? a.background,
      foreground: Color.lerp(a.foreground, b.foreground, t) ?? a.foreground,
      border: Color.lerp(a.border, b.border, t) ?? a.border ?? b.border,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppToneColors &&
        other.background == background &&
        other.foreground == foreground &&
        other.border == border;
  }

  @override
  int get hashCode => Object.hash(background, foreground, border);
}

@immutable
class AppThemeTokens extends ThemeExtension<AppThemeTokens> {
  const AppThemeTokens({
    required this.brand,
    required this.brandForeground,
    required this.shellGradient,
    required this.outerBackground,
    required this.panelBackground,
    required this.editorChromeBackground,
    required this.previewPanelBackground,
    required this.panelBorder,
    required this.toolbarOverlay,
    required this.timelineBackground,
    required this.timelineTrack,
    required this.timelineTick,
    required this.selectionFill,
    required this.noticeInfo,
    required this.noticeSuccess,
    required this.noticeWarning,
    required this.noticeError,
  });

  final Color brand;
  final Color brandForeground;
  final LinearGradient shellGradient;
  final Color outerBackground;
  final Color panelBackground;
  final Color editorChromeBackground;
  final Color previewPanelBackground;
  final Color panelBorder;
  final Color toolbarOverlay;
  final Color timelineBackground;
  final Color timelineTrack;
  final Color timelineTick;
  final Color selectionFill;
  final AppToneColors noticeInfo;
  final AppToneColors noticeSuccess;
  final AppToneColors noticeWarning;
  final AppToneColors noticeError;

  factory AppThemeTokens.fallback(Brightness brightness) =>
      _ResolvedPalette.forBrightness(brightness).tokens;

  @override
  AppThemeTokens copyWith({
    Color? brand,
    Color? brandForeground,
    LinearGradient? shellGradient,
    Color? outerBackground,
    Color? panelBackground,
    Color? editorChromeBackground,
    Color? previewPanelBackground,
    Color? panelBorder,
    Color? toolbarOverlay,
    Color? timelineBackground,
    Color? timelineTrack,
    Color? timelineTick,
    Color? selectionFill,
    AppToneColors? noticeInfo,
    AppToneColors? noticeSuccess,
    AppToneColors? noticeWarning,
    AppToneColors? noticeError,
  }) {
    return AppThemeTokens(
      brand: brand ?? this.brand,
      brandForeground: brandForeground ?? this.brandForeground,
      shellGradient: shellGradient ?? this.shellGradient,
      outerBackground: outerBackground ?? this.outerBackground,
      panelBackground: panelBackground ?? this.panelBackground,
      editorChromeBackground:
          editorChromeBackground ?? this.editorChromeBackground,
      previewPanelBackground:
          previewPanelBackground ?? this.previewPanelBackground,
      panelBorder: panelBorder ?? this.panelBorder,
      toolbarOverlay: toolbarOverlay ?? this.toolbarOverlay,
      timelineBackground: timelineBackground ?? this.timelineBackground,
      timelineTrack: timelineTrack ?? this.timelineTrack,
      timelineTick: timelineTick ?? this.timelineTick,
      selectionFill: selectionFill ?? this.selectionFill,
      noticeInfo: noticeInfo ?? this.noticeInfo,
      noticeSuccess: noticeSuccess ?? this.noticeSuccess,
      noticeWarning: noticeWarning ?? this.noticeWarning,
      noticeError: noticeError ?? this.noticeError,
    );
  }

  @override
  AppThemeTokens lerp(ThemeExtension<AppThemeTokens>? other, double t) {
    if (other is! AppThemeTokens) {
      return this;
    }

    return AppThemeTokens(
      brand: Color.lerp(brand, other.brand, t) ?? brand,
      brandForeground:
          Color.lerp(brandForeground, other.brandForeground, t) ??
          brandForeground,
      shellGradient:
          LinearGradient.lerp(shellGradient, other.shellGradient, t) ??
          shellGradient,
      outerBackground:
          Color.lerp(outerBackground, other.outerBackground, t) ??
          outerBackground,
      panelBackground:
          Color.lerp(panelBackground, other.panelBackground, t) ??
          panelBackground,
      editorChromeBackground:
          Color.lerp(editorChromeBackground, other.editorChromeBackground, t) ??
          editorChromeBackground,
      previewPanelBackground:
          Color.lerp(previewPanelBackground, other.previewPanelBackground, t) ??
          previewPanelBackground,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t) ?? panelBorder,
      toolbarOverlay:
          Color.lerp(toolbarOverlay, other.toolbarOverlay, t) ?? toolbarOverlay,
      timelineBackground:
          Color.lerp(timelineBackground, other.timelineBackground, t) ??
          timelineBackground,
      timelineTrack:
          Color.lerp(timelineTrack, other.timelineTrack, t) ?? timelineTrack,
      timelineTick:
          Color.lerp(timelineTick, other.timelineTick, t) ?? timelineTick,
      selectionFill:
          Color.lerp(selectionFill, other.selectionFill, t) ?? selectionFill,
      noticeInfo: AppToneColors.lerp(noticeInfo, other.noticeInfo, t),
      noticeSuccess: AppToneColors.lerp(noticeSuccess, other.noticeSuccess, t),
      noticeWarning: AppToneColors.lerp(noticeWarning, other.noticeWarning, t),
      noticeError: AppToneColors.lerp(noticeError, other.noticeError, t),
    );
  }
}

@immutable
class AppSpacingTokens extends ThemeExtension<AppSpacingTokens> {
  const AppSpacingTokens({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.xxl,
    required this.page,
    required this.panel,
    required this.dialog,
  });

  final double xs;
  final double sm;
  final double md;
  final double lg;
  final double xl;
  final double xxl;
  final double page;
  final double panel;
  final double dialog;

  factory AppSpacingTokens.fallback(Brightness brightness) =>
      _ResolvedPalette.forBrightness(brightness).spacingTokens;

  @override
  AppSpacingTokens copyWith({
    double? xs,
    double? sm,
    double? md,
    double? lg,
    double? xl,
    double? xxl,
    double? page,
    double? panel,
    double? dialog,
  }) {
    return AppSpacingTokens(
      xs: xs ?? this.xs,
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
      xl: xl ?? this.xl,
      xxl: xxl ?? this.xxl,
      page: page ?? this.page,
      panel: panel ?? this.panel,
      dialog: dialog ?? this.dialog,
    );
  }

  @override
  AppSpacingTokens lerp(ThemeExtension<AppSpacingTokens>? other, double t) {
    if (other is! AppSpacingTokens) {
      return this;
    }

    return AppSpacingTokens(
      xs: lerpDouble(xs, other.xs, t) ?? xs,
      sm: lerpDouble(sm, other.sm, t) ?? sm,
      md: lerpDouble(md, other.md, t) ?? md,
      lg: lerpDouble(lg, other.lg, t) ?? lg,
      xl: lerpDouble(xl, other.xl, t) ?? xl,
      xxl: lerpDouble(xxl, other.xxl, t) ?? xxl,
      page: lerpDouble(page, other.page, t) ?? page,
      panel: lerpDouble(panel, other.panel, t) ?? panel,
      dialog: lerpDouble(dialog, other.dialog, t) ?? dialog,
    );
  }
}

@immutable
class AppTypographyTokens extends ThemeExtension<AppTypographyTokens> {
  const AppTypographyTokens({
    required this.pageTitle,
    required this.panelTitle,
    required this.sectionEyebrow,
    required this.rowLabel,
    required this.body,
    required this.bodyMuted,
    required this.value,
    required this.button,
    required this.caption,
    required this.mono,
  });

  final TextStyle pageTitle;
  final TextStyle panelTitle;
  final TextStyle sectionEyebrow;
  final TextStyle rowLabel;
  final TextStyle body;
  final TextStyle bodyMuted;
  final TextStyle value;
  final TextStyle button;
  final TextStyle caption;
  final TextStyle mono;

  factory AppTypographyTokens.fallback(Brightness brightness) =>
      _ResolvedPalette.forBrightness(brightness).typographyTokens;

  @override
  AppTypographyTokens copyWith({
    TextStyle? pageTitle,
    TextStyle? panelTitle,
    TextStyle? sectionEyebrow,
    TextStyle? rowLabel,
    TextStyle? body,
    TextStyle? bodyMuted,
    TextStyle? value,
    TextStyle? button,
    TextStyle? caption,
    TextStyle? mono,
  }) {
    return AppTypographyTokens(
      pageTitle: pageTitle ?? this.pageTitle,
      panelTitle: panelTitle ?? this.panelTitle,
      sectionEyebrow: sectionEyebrow ?? this.sectionEyebrow,
      rowLabel: rowLabel ?? this.rowLabel,
      body: body ?? this.body,
      bodyMuted: bodyMuted ?? this.bodyMuted,
      value: value ?? this.value,
      button: button ?? this.button,
      caption: caption ?? this.caption,
      mono: mono ?? this.mono,
    );
  }

  @override
  AppTypographyTokens lerp(
    ThemeExtension<AppTypographyTokens>? other,
    double t,
  ) {
    if (other is! AppTypographyTokens) {
      return this;
    }

    return AppTypographyTokens(
      pageTitle: TextStyle.lerp(pageTitle, other.pageTitle, t) ?? pageTitle,
      panelTitle: TextStyle.lerp(panelTitle, other.panelTitle, t) ?? panelTitle,
      sectionEyebrow:
          TextStyle.lerp(sectionEyebrow, other.sectionEyebrow, t) ??
          sectionEyebrow,
      rowLabel: TextStyle.lerp(rowLabel, other.rowLabel, t) ?? rowLabel,
      body: TextStyle.lerp(body, other.body, t) ?? body,
      bodyMuted: TextStyle.lerp(bodyMuted, other.bodyMuted, t) ?? bodyMuted,
      value: TextStyle.lerp(value, other.value, t) ?? value,
      button: TextStyle.lerp(button, other.button, t) ?? button,
      caption: TextStyle.lerp(caption, other.caption, t) ?? caption,
      mono: TextStyle.lerp(mono, other.mono, t) ?? mono,
    );
  }
}

@immutable
class AppEditorChromeTokens extends ThemeExtension<AppEditorChromeTokens> {
  const AppEditorChromeTokens({
    required this.shellRadius,
    required this.panelRadius,
    required this.controlRadius,
    required this.pillRadius,
    required this.toolbarHeight,
    required this.editorRailWidth,
    required this.stagePadding,
    required this.compactControlHeight,
    required this.inspectorTabHeight,
    required this.timelineRulerHeight,
    required this.timelineLaneHeight,
    required this.timelineTrackHeaderWidth,
    required this.timelineHorizontalPadding,
    required this.timelineVerticalPadding,
  });

  final double shellRadius;
  final double panelRadius;
  final double controlRadius;
  final double pillRadius;
  final double toolbarHeight;
  final double editorRailWidth;
  final double stagePadding;
  final double compactControlHeight;
  final double inspectorTabHeight;
  final double timelineRulerHeight;
  final double timelineLaneHeight;
  final double timelineTrackHeaderWidth;
  final double timelineHorizontalPadding;
  final double timelineVerticalPadding;

  factory AppEditorChromeTokens.fallback(Brightness brightness) =>
      const AppEditorChromeTokens(
        shellRadius: 11,
        panelRadius: 9,
        controlRadius: 6,
        pillRadius: 999,
        toolbarHeight: 50,
        editorRailWidth: 60,
        stagePadding: 8,
        compactControlHeight: 32,
        inspectorTabHeight: 34,
        timelineRulerHeight: 70,
        timelineLaneHeight: 42,
        timelineTrackHeaderWidth: 92,
        timelineHorizontalPadding: 12,
        timelineVerticalPadding: 10,
      );

  @override
  AppEditorChromeTokens copyWith({
    double? shellRadius,
    double? panelRadius,
    double? controlRadius,
    double? pillRadius,
    double? toolbarHeight,
    double? editorRailWidth,
    double? stagePadding,
    double? compactControlHeight,
    double? inspectorTabHeight,
    double? timelineRulerHeight,
    double? timelineLaneHeight,
    double? timelineTrackHeaderWidth,
    double? timelineHorizontalPadding,
    double? timelineVerticalPadding,
  }) {
    return AppEditorChromeTokens(
      shellRadius: shellRadius ?? this.shellRadius,
      panelRadius: panelRadius ?? this.panelRadius,
      controlRadius: controlRadius ?? this.controlRadius,
      pillRadius: pillRadius ?? this.pillRadius,
      toolbarHeight: toolbarHeight ?? this.toolbarHeight,
      editorRailWidth: editorRailWidth ?? this.editorRailWidth,
      stagePadding: stagePadding ?? this.stagePadding,
      compactControlHeight: compactControlHeight ?? this.compactControlHeight,
      inspectorTabHeight: inspectorTabHeight ?? this.inspectorTabHeight,
      timelineRulerHeight: timelineRulerHeight ?? this.timelineRulerHeight,
      timelineLaneHeight: timelineLaneHeight ?? this.timelineLaneHeight,
      timelineTrackHeaderWidth:
          timelineTrackHeaderWidth ?? this.timelineTrackHeaderWidth,
      timelineHorizontalPadding:
          timelineHorizontalPadding ?? this.timelineHorizontalPadding,
      timelineVerticalPadding:
          timelineVerticalPadding ?? this.timelineVerticalPadding,
    );
  }

  @override
  AppEditorChromeTokens lerp(
    ThemeExtension<AppEditorChromeTokens>? other,
    double t,
  ) {
    if (other is! AppEditorChromeTokens) {
      return this;
    }

    return AppEditorChromeTokens(
      shellRadius: lerpDouble(shellRadius, other.shellRadius, t) ?? shellRadius,
      panelRadius: lerpDouble(panelRadius, other.panelRadius, t) ?? panelRadius,
      controlRadius:
          lerpDouble(controlRadius, other.controlRadius, t) ?? controlRadius,
      pillRadius: lerpDouble(pillRadius, other.pillRadius, t) ?? pillRadius,
      toolbarHeight:
          lerpDouble(toolbarHeight, other.toolbarHeight, t) ?? toolbarHeight,
      editorRailWidth:
          lerpDouble(editorRailWidth, other.editorRailWidth, t) ??
          editorRailWidth,
      stagePadding:
          lerpDouble(stagePadding, other.stagePadding, t) ?? stagePadding,
      compactControlHeight:
          lerpDouble(compactControlHeight, other.compactControlHeight, t) ??
          compactControlHeight,
      inspectorTabHeight:
          lerpDouble(inspectorTabHeight, other.inspectorTabHeight, t) ??
          inspectorTabHeight,
      timelineRulerHeight:
          lerpDouble(timelineRulerHeight, other.timelineRulerHeight, t) ??
          timelineRulerHeight,
      timelineLaneHeight:
          lerpDouble(timelineLaneHeight, other.timelineLaneHeight, t) ??
          timelineLaneHeight,
      timelineTrackHeaderWidth:
          lerpDouble(
            timelineTrackHeaderWidth,
            other.timelineTrackHeaderWidth,
            t,
          ) ??
          timelineTrackHeaderWidth,
      timelineHorizontalPadding:
          lerpDouble(
            timelineHorizontalPadding,
            other.timelineHorizontalPadding,
            t,
          ) ??
          timelineHorizontalPadding,
      timelineVerticalPadding:
          lerpDouble(
            timelineVerticalPadding,
            other.timelineVerticalPadding,
            t,
          ) ??
          timelineVerticalPadding,
    );
  }
}

extension AppThemeDataX on ThemeData {
  AppThemeTokens get appTokens =>
      extension<AppThemeTokens>() ?? AppThemeTokens.fallback(brightness);
  AppSpacingTokens get appSpacing =>
      extension<AppSpacingTokens>() ?? AppSpacingTokens.fallback(brightness);
  AppTypographyTokens get appTypography =>
      extension<AppTypographyTokens>() ??
      AppTypographyTokens.fallback(brightness);
  AppEditorChromeTokens get appEditorChrome =>
      extension<AppEditorChromeTokens>() ??
      AppEditorChromeTokens.fallback(brightness);
}

extension AppThemeContextX on BuildContext {
  AppThemeTokens get appTokens => Theme.of(this).appTokens;
  AppSpacingTokens get appSpacing => Theme.of(this).appSpacing;
  AppTypographyTokens get appTypography => Theme.of(this).appTypography;
  AppEditorChromeTokens get appEditorChrome => Theme.of(this).appEditorChrome;
}

ThemeData buildThemeData(Brightness brightness) {
  final palette = _ResolvedPalette.forBrightness(brightness);
  final spacing = palette.spacingTokens;
  final typography = palette.typographyTokens;
  final chrome = AppEditorChromeTokens.fallback(brightness);
  final radius = BorderRadius.circular(chrome.controlRadius);
  final inputBorder = OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: palette.border),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
    primaryColor: clingfyBrandColor,
    scaffoldBackgroundColor: palette.scaffoldBackground,
    canvasColor: palette.surfaceRaised,
    cardColor: palette.surface,
    dividerColor: palette.border,
    colorScheme: palette.colorScheme,
    extensions: <ThemeExtension<dynamic>>[
      palette.tokens,
      spacing,
      typography,
      chrome,
    ],
    textTheme: TextTheme(
      bodyLarge: typography.body.copyWith(fontSize: 14),
      bodyMedium: typography.body,
      bodySmall: typography.bodyMuted,
      labelLarge: typography.button,
      labelMedium: typography.value,
      titleMedium: typography.rowLabel.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: 15,
      ),
      titleLarge: typography.panelTitle,
      headlineSmall: typography.pageTitle,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.controlFill,
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: clingfyBrandColor, width: 1.4),
      ),
      disabledBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: palette.border.withValues(alpha: 0.65)),
      ),
      contentPadding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm + 2,
      ),
      labelStyle: typography.value,
      hintStyle: typography.bodyMuted,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.controlFill,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: clingfyBrandColor, width: 1.4),
        ),
      ),
      textStyle: typography.body,
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.surface),
        side: WidgetStatePropertyAll(BorderSide(color: palette.border)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.tokens.panelBackground,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(
        alpha: brightness == Brightness.dark ? 0.28 : 0.06,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(chrome.panelRadius),
        side: BorderSide(color: palette.tokens.panelBorder),
      ),
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        shadowColor: Colors.transparent,
        backgroundColor: clingfyBrandColor,
        foregroundColor: palette.brandForeground,
        disabledBackgroundColor: brightness == Brightness.dark
            ? palette.controlFill
            : palette.surfaceSubtle,
        disabledForegroundColor: palette.textSecondary,
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: typography.button,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        elevation: 0,
        shadowColor: Colors.transparent,
        backgroundColor: palette.surface,
        foregroundColor: palette.textPrimary,
        side: BorderSide(color: palette.borderStrong),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: typography.button,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: clingfyBrandColor,
        textStyle: typography.button,
      ),
    ),
    iconTheme: IconThemeData(color: palette.textSecondary, size: 18),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(palette.textSecondary),
        overlayColor: WidgetStatePropertyAll(
          clingfyBrandColor.withValues(alpha: 0.08),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: palette.border, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.tokens.editorChromeBackground,
      surfaceTintColor: Colors.transparent,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: clingfyBrandColor,
      activeTickMarkColor: clingfyBrandColor,
      inactiveTrackColor: brightness == Brightness.dark
          ? palette.controlFill
          : palette.surfaceSubtle,
      disabledActiveTrackColor: palette.borderStrong,
      disabledInactiveTrackColor: palette.border,
      thumbColor: brightness == Brightness.dark
          ? Colors.white
          : clingfyBrandColor,
      overlayColor:
          (brightness == Brightness.dark ? Colors.white : clingfyBrandColor)
              .withValues(alpha: brightness == Brightness.dark ? 0.12 : 0.16),
      valueIndicatorColor: clingfyBrandColor,
      valueIndicatorTextStyle: typography.value.copyWith(
        color: palette.brandForeground,
      ),
      trackHeight: 4,
      thumbShape: RoundSliderThumbShape(
        enabledThumbRadius: brightness == Brightness.dark ? 5 : 6,
        disabledThumbRadius: brightness == Brightness.dark ? 5 : 6,
      ),
      overlayShape: RoundSliderOverlayShape(
        overlayRadius: brightness == Brightness.dark ? 14 : 16,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return palette.brandForeground;
        }
        return palette.surface;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return clingfyBrandColor.withValues(alpha: 0.5);
        }
        return brightness == Brightness.dark
            ? palette.controlFill
            : palette.surfaceSubtle;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return clingfyBrandColor.withValues(alpha: 0.35);
        }
        return palette.border;
      }),
    ),
  );
}

MacosThemeData buildMacosTheme(Brightness brightness) {
  final palette = _ResolvedPalette.forBrightness(brightness);
  final typography = palette.typographyTokens;
  final isDark = brightness == Brightness.dark;

  return MacosThemeData(
    brightness: brightness,
    primaryColor: clingfyBrandColor,
    canvasColor: palette.tokens.panelBackground,
    dividerColor: palette.tokens.panelBorder,
    pushButtonTheme: PushButtonThemeData(
      color: clingfyBrandColor,
      secondaryColor: palette.controlFill,
      disabledColor: brightness == Brightness.dark
          ? palette.controlFill
          : palette.surfaceSubtle,
    ),
    macosIconButtonTheme: MacosIconButtonThemeData(
      backgroundColor: Colors.transparent,
      disabledColor: brightness == Brightness.dark
          ? palette.controlFill
          : palette.surfaceSubtle,
      hoverColor: clingfyBrandColor.withValues(alpha: isDark ? 0.18 : 0.08),
      shape: BoxShape.circle,
      boxConstraints: const BoxConstraints(
        minHeight: 20,
        minWidth: 20,
        maxWidth: 30,
        maxHeight: 30,
      ),
    ),
    iconTheme: MacosIconThemeData(color: palette.textSecondary, size: 20),
    popupButtonTheme: MacosPopupButtonThemeData(
      highlightColor: clingfyBrandColor,
      backgroundColor: palette.controlFill,
      popupColor: palette.surface,
    ),
    pulldownButtonTheme: MacosPulldownButtonThemeData(
      highlightColor: clingfyBrandColor,
      backgroundColor: palette.controlFill,
      pulldownColor: palette.surface,
      iconColor: palette.textSecondary,
    ),
    helpButtonTheme: HelpButtonThemeData(
      color: palette.controlFill,
      disabledColor: brightness == Brightness.dark
          ? palette.controlFill
          : palette.surfaceSubtle,
    ),
    tooltipTheme: MacosTooltipThemeData.standard(
      brightness: brightness,
      textStyle: typography.bodyMuted.copyWith(color: palette.textPrimary),
    ),
  );
}

fluent.FluentThemeData buildFluentTheme(Brightness brightness) {
  final palette = _ResolvedPalette.forBrightness(brightness);
  final accent = clingfyBrandColor.toAccentColor();

  return fluent.FluentThemeData(
    brightness: brightness,
    accentColor: accent,
    selectionColor: accent.defaultBrushFor(brightness),
    scaffoldBackgroundColor: palette.scaffoldBackground,
    acrylicBackgroundColor: brightness == Brightness.dark
        ? palette.surface
        : palette.surfaceRaised,
    micaBackgroundColor: palette.scaffoldBackground,
    cardColor: palette.surface,
    menuColor: brightness == Brightness.dark
        ? palette.surface
        : palette.surfaceRaised,
    inactiveBackgroundColor: brightness == Brightness.dark
        ? palette.controlFill
        : palette.surfaceSubtle,
    inactiveColor: palette.textPrimary,
    shadowColor: Colors.black.withValues(
      alpha: brightness == Brightness.dark ? 0.3 : 0.08,
    ),
    dialogTheme: fluent.ContentDialogThemeData(
      decoration: BoxDecoration(
        color: palette.tokens.editorChromeBackground,
        borderRadius: BorderRadius.circular(12),
        boxShadow: kElevationToShadow[6],
      ),
      actionsDecoration: BoxDecoration(
        color: palette.tokens.editorChromeBackground,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      ),
    ),
    iconTheme: IconThemeData(color: palette.textSecondary, size: 18),
  );
}

ThemeData buildLightTheme() => buildThemeData(Brightness.light);
ThemeData buildDarkTheme() => buildThemeData(Brightness.dark);

class _ResolvedPalette {
  const _ResolvedPalette({
    required this.scaffoldBackground,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSubtle,
    required this.controlFill,
    required this.textPrimary,
    required this.textSecondary,
    required this.border,
    required this.borderStrong,
    required this.brandForeground,
    required this.colorScheme,
    required this.tokens,
  });

  final Color scaffoldBackground;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceSubtle;
  final Color controlFill;
  final Color textPrimary;
  final Color textSecondary;
  final Color border;
  final Color borderStrong;
  final Color brandForeground;
  final ColorScheme colorScheme;
  final AppThemeTokens tokens;
  AppSpacingTokens get spacingTokens => const AppSpacingTokens(
    xs: 4,
    sm: 8,
    md: 12,
    lg: 16,
    xl: 20,
    xxl: 24,
    page: 16,
    panel: 20,
    dialog: 24,
  );

  AppTypographyTokens get typographyTokens => AppTypographyTokens(
    pageTitle: TextStyle(
      color: textPrimary,
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.15,
    ),
    panelTitle: TextStyle(
      color: textPrimary,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.2,
    ),
    sectionEyebrow: TextStyle(
      color: textSecondary,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
      height: 1.2,
    ),
    rowLabel: TextStyle(
      color: textPrimary,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.25,
    ),
    body: TextStyle(color: textPrimary, fontSize: 13, height: 1.35),
    bodyMuted: TextStyle(color: textSecondary, fontSize: 12, height: 1.35),
    value: TextStyle(
      color: textSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.25,
    ),
    button: TextStyle(
      color: textPrimary,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.2,
    ),
    caption: TextStyle(
      color: textSecondary,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      height: 1.2,
    ),
    mono: TextStyle(
      color: textSecondary,
      fontFamily: 'monospace',
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.2,
    ),
  );

  factory _ResolvedPalette.forBrightness(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final brandForeground =
        ThemeData.estimateBrightnessForColor(clingfyBrandColor) ==
            Brightness.dark
        ? Colors.white
        : const Color(0xFF160D24);

    const darkOuterBackground = Color(0xFF05070B);
    const darkPrimarySurface = Color(0xFF0E1318);
    const darkSecondarySurface = Color(0xFF2A2D35);
    const darkEditorChromeSurface = Color(0xFF15161A);
    const darkPreviewSurface = Color(0xFF151718);
    const darkTimelineSurface = Color(0xFF111113);
    const lightSurface = Colors.white;
    const lightSurfaceRaised = Color(0xFFF7F3FD);
    const lightSurfaceSubtle = Color(0xFFF0EAFB);

    final scaffoldBackground = isDark
        ? darkOuterBackground
        : const Color(0xFFF7F4FC);
    final surface = isDark ? darkPrimarySurface : lightSurface;
    final surfaceRaised = isDark ? darkPrimarySurface : lightSurfaceRaised;
    final surfaceSubtle = isDark ? darkPrimarySurface : lightSurfaceSubtle;
    final controlFill = isDark ? darkSecondarySurface : lightSurfaceRaised;
    final textPrimary = isDark
        ? const Color(0xFFF5F2FF)
        : const Color(0xFF241A35);
    final textSecondary = isDark
        ? const Color(0xFFBAB7C8)
        : const Color(0xFF6F6685);
    final border = isDark ? const Color(0xFF2E2E39) : const Color(0xFFD7CDEA);
    final borderStrong = isDark
        ? const Color(0xFF3D3D4B)
        : const Color(0xFFC2B3E4);
    final primaryContainer = isDark
        ? const Color(0xFF262036)
        : const Color(0xFFEDE4FF);
    final onPrimaryContainer = isDark
        ? const Color(0xFFF0E7FF)
        : const Color(0xFF352254);
    final error = isDark ? const Color(0xFFFF8B9A) : const Color(0xFFB32643);

    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: clingfyBrandColor,
          brightness: brightness,
        ).copyWith(
          primary: clingfyBrandColor,
          onPrimary: brandForeground,
          primaryContainer: primaryContainer,
          onPrimaryContainer: onPrimaryContainer,
          secondary: isDark ? const Color(0xFFC9B9F3) : const Color(0xFF7455B8),
          onSecondary: brandForeground,
          secondaryContainer: controlFill,
          onSecondaryContainer: textPrimary,
          surface: surface,
          onSurface: textPrimary,
          surfaceContainerLowest: surface,
          surfaceContainerLow: isDark ? surface : surfaceRaised,
          surfaceContainer: isDark ? surface : surfaceRaised,
          surfaceContainerHigh: isDark ? surface : surfaceSubtle,
          surfaceContainerHighest: isDark
              ? surface
              : _blend(clingfyBrandColor, surface, 0.1),
          onSurfaceVariant: textSecondary,
          outline: borderStrong,
          outlineVariant: border,
          error: error,
          onError: Colors.white,
          errorContainer: _blend(error, surface, isDark ? 0.18 : 0.1),
          onErrorContainer: isDark
              ? const Color(0xFFFFD9DD)
              : const Color(0xFF4B1020),
          scrim: Colors.black.withValues(alpha: isDark ? 0.72 : 0.55),
          shadow: Colors.black.withValues(alpha: isDark ? 0.34 : 0.12),
        );

    final tokens = AppThemeTokens(
      brand: clingfyBrandColor,
      brandForeground: brandForeground,
      shellGradient: LinearGradient(
        colors: isDark
            ? const [darkOuterBackground, darkOuterBackground]
            : const [Color(0xFFF9F6FF), Color(0xFFF4F8FF)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      outerBackground: isDark ? darkOuterBackground : const Color(0xFFF7F4FC),
      panelBackground: isDark ? darkPrimarySurface : const Color(0xF7FFFFFF),
      editorChromeBackground: isDark
          ? darkEditorChromeSurface
          : const Color(0xF7FFFFFF),
      previewPanelBackground: isDark
          ? darkPreviewSurface
          : const Color(0xF7FFFFFF),
      panelBorder: isDark ? border : border.withValues(alpha: 0.95),
      toolbarOverlay: isDark ? darkPrimarySurface : const Color(0xF2FFFFFF),
      timelineBackground: isDark
          ? darkTimelineSurface
          : const Color(0xFFFDFBFF),
      timelineTrack: isDark ? const Color(0xFF1D1D26) : const Color(0xFFE7E0F6),
      timelineTick: isDark ? const Color(0xFF807B93) : const Color(0xFF9288AA),
      selectionFill: clingfyBrandColor.withValues(alpha: isDark ? 0.2 : 0.12),
      noticeInfo: AppToneColors(
        background: _blend(clingfyBrandColor, surface, isDark ? 0.2 : 0.1),
        foreground: isDark ? const Color(0xFFD5C6FF) : const Color(0xFF5F3FA9),
        border: clingfyBrandColor.withValues(alpha: isDark ? 0.28 : 0.16),
      ),
      noticeSuccess: AppToneColors(
        background: _blend(
          const Color(0xFF3BA55D),
          surface,
          isDark ? 0.2 : 0.1,
        ),
        foreground: isDark ? const Color(0xFFABEDBC) : const Color(0xFF2F7C46),
        border: const Color(0xFF3BA55D).withValues(alpha: isDark ? 0.28 : 0.16),
      ),
      noticeWarning: AppToneColors(
        background: _blend(
          const Color(0xFFF3A635),
          surface,
          isDark ? 0.22 : 0.12,
        ),
        foreground: isDark ? const Color(0xFFFFDEA3) : const Color(0xFF8A5A12),
        border: const Color(0xFFF3A635).withValues(alpha: isDark ? 0.28 : 0.18),
      ),
      noticeError: AppToneColors(
        background: _blend(error, surface, isDark ? 0.22 : 0.1),
        foreground: isDark ? const Color(0xFFFFC1C8) : const Color(0xFF8F243B),
        border: error.withValues(alpha: isDark ? 0.28 : 0.18),
      ),
    );

    return _ResolvedPalette(
      scaffoldBackground: scaffoldBackground,
      surface: surface,
      surfaceRaised: surfaceRaised,
      surfaceSubtle: surfaceSubtle,
      controlFill: controlFill,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      border: border,
      borderStrong: borderStrong,
      brandForeground: brandForeground,
      colorScheme: colorScheme,
      tokens: tokens,
    );
  }
}

Color _blend(Color tint, Color base, double alpha) {
  return Color.alphaBlend(tint.withValues(alpha: alpha), base);
}
