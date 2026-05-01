import 'package:flutter/widgets.dart';

/// Density tier for the Home/editor shell, derived from window width.
enum ShellDensity { comfortable, compact, dense, minimal }

/// Centralized responsive sizing for the Home shell chrome.
///
/// One instance is computed near the shell root via [LayoutBuilder] and exposed
/// through [ResponsiveShellScope]. Widgets read it with `context.shellMetrics`.
@immutable
class ShellResponsiveMetrics {
  const ShellResponsiveMetrics({
    required this.density,
    required this.scale,
    required this.railWidth,
    required this.railCompactWidth,
    required this.railButtonSize,
    required this.railIconSize,
    required this.railLogoSizeCompact,
    required this.railLogoSizeExpanded,
    required this.railHorizontalPaddingCompact,
    required this.railTopPaddingCompact,
    required this.railBottomPaddingCompact,
    required this.railHeaderGapCompact,
    required this.railSectionGapCompact,
    required this.railUtilityGap,
    required this.railUtilityBottomInset,
    required this.expandedNavButtonHeight,
    required this.expandedNavButtonIconSize,
    required this.expandedNavButtonGap,
    required this.expandedNavButtonHorizontalPadding,
    required this.expandedNavButtonVerticalPadding,
    required this.expandedSidebarPadding,
    required this.expandedSidebarHeaderGap,
    required this.expandedSidebarTitleSpacing,
    required this.expandedSidebarLogoTitleGap,
    required this.expandedSidebarSplashRadius,
    required this.optionsPanelDefaultWidth,
    required this.optionsPanelMinWidth,
    required this.optionsPanelMaxWidth,
    required this.toolbarHeight,
    required this.toolbarHorizontalPadding,
    required this.toolbarIconButtonSize,
    required this.toolbarIconSize,
    required this.toolbarPillIconSize,
    required this.panelGap,
    required this.panelRadius,
    required this.controlRadius,
    required this.stagePadding,
    required this.heroIconSize,
    required this.heroButtonHeight,
    required this.heroButtonMinWidth,
    required this.heroTitleScale,
    required this.gridStep,
    required this.paneHeaderTopPadding,
    required this.paneHeaderBottomPadding,
    required this.paneHeaderTitleSize,
    required this.sidebarSectionGap,
    required this.sidebarRowGap,
    required this.sidebarCompactGap,
    required this.sidebarCompactRowGap,
    required this.sidebarControlGap,
    required this.sidebarOptionsGroupGap,
    required this.sidebarOptionsSubgroupGap,
    required this.sidebarInsetPadding,
    required this.sidebarInsetRadius,
    required this.sidebarContentHorizontalPadding,
    required this.sidebarContentHorizontalPaddingCompact,
    required this.sidebarHeaderContentGap,
    required this.sidebarRailItemGap,
    required this.sidebarRailItemVerticalPadding,
    required this.sidebarLabelWidth,
    required this.sidebarStackBreakpoint,
    required this.sidebarCompactWidthBreakpoint,
    required this.sidebarControlMinWidth,
    required this.sidebarControlMaxWidth,
    required this.sidebarControlHeightMac,
    required this.sidebarControlHeightDefault,
    required this.sidebarCompactButtonHeight,
    required this.sidebarIconSmall,
    required this.sidebarIconMedium,
    required this.sidebarActionIconSize,
    required this.autoCollapseOptions,
    required this.autoCompactRail,
  });

  final ShellDensity density;
  final double scale;

  final double railWidth;
  final double railCompactWidth;
  final double railButtonSize;
  final double railIconSize;
  final double railLogoSizeCompact;
  final double railLogoSizeExpanded;
  final double railHorizontalPaddingCompact;
  final double railTopPaddingCompact;
  final double railBottomPaddingCompact;
  final double railHeaderGapCompact;
  final double railSectionGapCompact;
  final double railUtilityGap;
  final double railUtilityBottomInset;
  final double expandedNavButtonHeight;
  final double expandedNavButtonIconSize;
  final double expandedNavButtonGap;
  final double expandedNavButtonHorizontalPadding;
  final double expandedNavButtonVerticalPadding;
  final double expandedSidebarPadding;
  final double expandedSidebarHeaderGap;
  final double expandedSidebarTitleSpacing;
  final double expandedSidebarLogoTitleGap;
  final double expandedSidebarSplashRadius;

  final double optionsPanelDefaultWidth;
  final double optionsPanelMinWidth;
  final double optionsPanelMaxWidth;

  final double toolbarHeight;
  final double toolbarHorizontalPadding;
  final double toolbarIconButtonSize;
  final double toolbarIconSize;
  final double toolbarPillIconSize;

  final double panelGap;
  final double panelRadius;
  final double controlRadius;
  final double stagePadding;

  final double heroIconSize;
  final double heroButtonHeight;
  final double heroButtonMinWidth;
  final double heroTitleScale;

  final double gridStep;

  final double paneHeaderTopPadding;
  final double paneHeaderBottomPadding;
  final double paneHeaderTitleSize;

  final double sidebarSectionGap;
  final double sidebarRowGap;
  final double sidebarCompactGap;
  final double sidebarCompactRowGap;
  final double sidebarControlGap;
  final double sidebarOptionsGroupGap;
  final double sidebarOptionsSubgroupGap;
  final double sidebarInsetPadding;
  final double sidebarInsetRadius;
  final double sidebarContentHorizontalPadding;
  final double sidebarContentHorizontalPaddingCompact;
  final double sidebarHeaderContentGap;
  final double sidebarRailItemGap;
  final double sidebarRailItemVerticalPadding;
  final double sidebarLabelWidth;
  final double sidebarStackBreakpoint;
  final double sidebarCompactWidthBreakpoint;
  final double sidebarControlMinWidth;
  final double sidebarControlMaxWidth;
  final double sidebarControlHeightMac;
  final double sidebarControlHeightDefault;
  final double sidebarCompactButtonHeight;
  final double sidebarIconSmall;
  final double sidebarIconMedium;
  final double sidebarActionIconSize;

  /// True when window is narrow enough that the options panel should auto
  /// collapse / be hidden by default.
  final bool autoCollapseOptions;

  /// True when window is narrow enough that the navigation rail should switch
  /// to its compact (icon-only) presentation automatically.
  final bool autoCompactRail;

  static ShellDensity densityForWidth(double width) {
    if (width >= 1400) return ShellDensity.comfortable;
    if (width >= 1200) return ShellDensity.compact;
    if (width >= 1000) return ShellDensity.dense;
    return ShellDensity.minimal;
  }

  static double scaleForDensity(ShellDensity density) {
    switch (density) {
      case ShellDensity.comfortable:
        return 1.0;
      case ShellDensity.compact:
        return 0.92;
      case ShellDensity.dense:
        return 0.84;
      case ShellDensity.minimal:
        return 0.78;
    }
  }

  factory ShellResponsiveMetrics.fromSize(Size size) {
    final density = densityForWidth(size.width);
    final scale = scaleForDensity(density);
    final isMinimal = density == ShellDensity.minimal;

    return ShellResponsiveMetrics(
      density: density,
      scale: scale,
      railWidth: _lerpForDensity(
        density,
        comfortable: 220,
        compact: 204,
        dense: 188,
        minimal: 176,
      ),
      railCompactWidth: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 64,
          compact: 58,
          dense: 52,
          minimal: 48,
        ),
        46,
      ),
      railButtonSize: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 40,
          compact: 38,
          dense: 36,
          minimal: 34,
        ),
        34,
      ),
      railIconSize: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 28,
          compact: 26,
          dense: 24,
          minimal: 22,
        ),
        20,
      ),
      railLogoSizeCompact: _atLeast(30 * scale, 22),
      railLogoSizeExpanded: _atLeast(36 * scale, 26),
      railHorizontalPaddingCompact: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 6,
          compact: 5,
          dense: 4,
          minimal: 3,
        ),
        2,
      ),
      railTopPaddingCompact: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 14,
          compact: 12,
          dense: 10,
          minimal: 8,
        ),
        6,
      ),
      railBottomPaddingCompact: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 8,
          compact: 6,
          dense: 4,
          minimal: 3,
        ),
        2,
      ),
      railHeaderGapCompact: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 6,
          compact: 5,
          dense: 4,
          minimal: 3,
        ),
        2,
      ),
      railSectionGapCompact: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 12,
          compact: 10,
          dense: 8,
          minimal: 6,
        ),
        4,
      ),
      railUtilityGap: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 8,
          compact: 7,
          dense: 6,
          minimal: 5,
        ),
        4,
      ),
      railUtilityBottomInset: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 6,
          compact: 5,
          dense: 4,
          minimal: 3,
        ),
        2,
      ),
      expandedNavButtonHeight: _atLeast(44 * scale, 36),
      expandedNavButtonIconSize: _atLeast(20 * scale, 16),
      expandedNavButtonGap: _atLeast(12 * scale, 8),
      expandedNavButtonHorizontalPadding: _atLeast(12 * scale, 8),
      expandedNavButtonVerticalPadding: _atLeast(10 * scale, 6),
      expandedSidebarPadding: _atLeast(12 * scale, 8),
      expandedSidebarHeaderGap: _atLeast(18 * scale, 10),
      expandedSidebarTitleSpacing: _atLeast(2 * scale, 1),
      expandedSidebarLogoTitleGap: _atLeast(12 * scale, 8),
      expandedSidebarSplashRadius: _atLeast(18 * scale, 14),
      optionsPanelDefaultWidth: _lerpForDensity(
        density,
        comfortable: 332,
        compact: 308,
        dense: 280,
        minimal: 272,
      ),
      optionsPanelMinWidth: _lerpForDensity(
        density,
        comfortable: 280,
        compact: 264,
        dense: 248,
        minimal: 240,
      ),
      optionsPanelMaxWidth: _lerpForDensity(
        density,
        comfortable: 420,
        compact: 380,
        dense: 340,
        minimal: 320,
      ),
      toolbarHeight: _atLeast(50 * scale, 38),
      toolbarHorizontalPadding: _atLeast(10 * scale, 6),
      toolbarIconButtonSize: _atLeast(32 * scale, 26),
      toolbarIconSize: _atLeast(17 * scale, 14),
      toolbarPillIconSize: _atLeast(12 * scale, 10),
      panelGap: _atLeast(4 * scale, 3),
      panelRadius: _atLeast(9 * scale, 8),
      controlRadius: _atLeast(6 * scale, 5),
      stagePadding: _atLeast(8 * scale, 6),
      heroIconSize: _atLeast(64 * scale, 36),
      heroButtonHeight: _atLeast(48 * scale, 36),
      heroButtonMinWidth: _atLeast(180 * scale, 132),
      heroTitleScale: _clampDouble(0.86 + (scale - 0.78) * 0.6, 0.86, 1.0),
      gridStep: _atLeast(40 * scale, 24),
      paneHeaderTopPadding: _atLeast(12 * scale, 8),
      paneHeaderBottomPadding: _atLeast(10 * scale, 7),
      paneHeaderTitleSize: _atLeast(16 * scale, 14),
      sidebarSectionGap: _atLeast(12 * scale, 8),
      sidebarRowGap: _atLeast(8 * scale, 5),
      sidebarCompactGap: _atLeast(4 * scale, 3),
      sidebarCompactRowGap: _atLeast(4 * scale, 3),
      sidebarControlGap: _atLeast(10 * scale, 6),
      sidebarOptionsGroupGap: _atLeast(16 * scale, 10),
      sidebarOptionsSubgroupGap: _atLeast(12 * scale, 8),
      sidebarInsetPadding: _atLeast(12 * scale, 8),
      sidebarInsetRadius: _atLeast(12 * scale, 8),
      sidebarContentHorizontalPadding: _atLeast(12 * scale, 8),
      sidebarContentHorizontalPaddingCompact: _atLeast(10 * scale, 8),
      sidebarHeaderContentGap: _atLeast(12 * scale, 8),
      sidebarRailItemGap: _atLeast(12 * scale, 6),
      sidebarRailItemVerticalPadding: _atLeast(6 * scale, 4),
      sidebarLabelWidth: _atLeast(164 * scale, 128),
      sidebarStackBreakpoint: _atLeast(520 * scale, 360),
      sidebarCompactWidthBreakpoint: _atLeast(320 * scale, 260),
      sidebarControlMinWidth: _atLeast(220 * scale, 160),
      sidebarControlMaxWidth: _atLeast(360 * scale, 240),
      sidebarControlHeightMac: _atLeast(32 * scale, 28),
      sidebarControlHeightDefault: _atLeast(34 * scale, 28),
      sidebarCompactButtonHeight: _atLeast(32 * scale, 28),
      sidebarIconSmall: _atLeast(14 * scale, 12),
      sidebarIconMedium: _atLeast(18 * scale, 14),
      sidebarActionIconSize: _atLeast(20 * scale, 16),
      autoCollapseOptions: isMinimal,
      autoCompactRail: isMinimal,
    );
  }

  static double _atLeast(double value, double minimum) =>
      value < minimum ? minimum : value;

  static double _clampDouble(double value, double minimum, double maximum) {
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
  }

  static double _lerpForDensity(
    ShellDensity density, {
    required double comfortable,
    required double compact,
    required double dense,
    required double minimal,
  }) {
    switch (density) {
      case ShellDensity.comfortable:
        return comfortable;
      case ShellDensity.compact:
        return compact;
      case ShellDensity.dense:
        return dense;
      case ShellDensity.minimal:
        return minimal;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ShellResponsiveMetrics &&
        other.density == density &&
        other.scale == scale &&
        other.railWidth == railWidth &&
        other.railCompactWidth == railCompactWidth &&
        other.railButtonSize == railButtonSize &&
        other.railIconSize == railIconSize &&
        other.railLogoSizeCompact == railLogoSizeCompact &&
        other.railLogoSizeExpanded == railLogoSizeExpanded &&
        other.railHorizontalPaddingCompact == railHorizontalPaddingCompact &&
        other.railTopPaddingCompact == railTopPaddingCompact &&
        other.railBottomPaddingCompact == railBottomPaddingCompact &&
        other.railHeaderGapCompact == railHeaderGapCompact &&
        other.railSectionGapCompact == railSectionGapCompact &&
        other.railUtilityGap == railUtilityGap &&
        other.railUtilityBottomInset == railUtilityBottomInset &&
        other.expandedNavButtonHeight == expandedNavButtonHeight &&
        other.expandedNavButtonIconSize == expandedNavButtonIconSize &&
        other.expandedNavButtonGap == expandedNavButtonGap &&
        other.expandedNavButtonHorizontalPadding ==
            expandedNavButtonHorizontalPadding &&
        other.expandedNavButtonVerticalPadding ==
            expandedNavButtonVerticalPadding &&
        other.expandedSidebarPadding == expandedSidebarPadding &&
        other.expandedSidebarHeaderGap == expandedSidebarHeaderGap &&
        other.expandedSidebarTitleSpacing == expandedSidebarTitleSpacing &&
        other.expandedSidebarLogoTitleGap == expandedSidebarLogoTitleGap &&
        other.expandedSidebarSplashRadius == expandedSidebarSplashRadius &&
        other.optionsPanelDefaultWidth == optionsPanelDefaultWidth &&
        other.optionsPanelMinWidth == optionsPanelMinWidth &&
        other.optionsPanelMaxWidth == optionsPanelMaxWidth &&
        other.toolbarHeight == toolbarHeight &&
        other.toolbarHorizontalPadding == toolbarHorizontalPadding &&
        other.toolbarIconButtonSize == toolbarIconButtonSize &&
        other.toolbarIconSize == toolbarIconSize &&
        other.toolbarPillIconSize == toolbarPillIconSize &&
        other.panelGap == panelGap &&
        other.panelRadius == panelRadius &&
        other.controlRadius == controlRadius &&
        other.stagePadding == stagePadding &&
        other.heroIconSize == heroIconSize &&
        other.heroButtonHeight == heroButtonHeight &&
        other.heroButtonMinWidth == heroButtonMinWidth &&
        other.heroTitleScale == heroTitleScale &&
        other.gridStep == gridStep &&
        other.paneHeaderTopPadding == paneHeaderTopPadding &&
        other.paneHeaderBottomPadding == paneHeaderBottomPadding &&
        other.paneHeaderTitleSize == paneHeaderTitleSize &&
        other.sidebarSectionGap == sidebarSectionGap &&
        other.sidebarRowGap == sidebarRowGap &&
        other.sidebarCompactGap == sidebarCompactGap &&
        other.sidebarCompactRowGap == sidebarCompactRowGap &&
        other.sidebarControlGap == sidebarControlGap &&
        other.sidebarOptionsGroupGap == sidebarOptionsGroupGap &&
        other.sidebarOptionsSubgroupGap == sidebarOptionsSubgroupGap &&
        other.sidebarInsetPadding == sidebarInsetPadding &&
        other.sidebarInsetRadius == sidebarInsetRadius &&
        other.sidebarContentHorizontalPadding ==
            sidebarContentHorizontalPadding &&
        other.sidebarContentHorizontalPaddingCompact ==
            sidebarContentHorizontalPaddingCompact &&
        other.sidebarHeaderContentGap == sidebarHeaderContentGap &&
        other.sidebarRailItemGap == sidebarRailItemGap &&
        other.sidebarRailItemVerticalPadding ==
            sidebarRailItemVerticalPadding &&
        other.sidebarLabelWidth == sidebarLabelWidth &&
        other.sidebarStackBreakpoint == sidebarStackBreakpoint &&
        other.sidebarCompactWidthBreakpoint ==
            sidebarCompactWidthBreakpoint &&
        other.sidebarControlMinWidth == sidebarControlMinWidth &&
        other.sidebarControlMaxWidth == sidebarControlMaxWidth &&
        other.sidebarControlHeightMac == sidebarControlHeightMac &&
        other.sidebarControlHeightDefault == sidebarControlHeightDefault &&
        other.sidebarCompactButtonHeight == sidebarCompactButtonHeight &&
        other.sidebarIconSmall == sidebarIconSmall &&
        other.sidebarIconMedium == sidebarIconMedium &&
        other.sidebarActionIconSize == sidebarActionIconSize &&
        other.autoCollapseOptions == autoCollapseOptions &&
        other.autoCompactRail == autoCompactRail;
  }

  @override
  int get hashCode => Object.hashAll([
    density,
    scale,
    railWidth,
    railCompactWidth,
    railButtonSize,
    railIconSize,
    railLogoSizeCompact,
    railLogoSizeExpanded,
    railHorizontalPaddingCompact,
    railTopPaddingCompact,
    railBottomPaddingCompact,
    railHeaderGapCompact,
    railSectionGapCompact,
    railUtilityGap,
    railUtilityBottomInset,
    expandedNavButtonHeight,
    expandedNavButtonIconSize,
    expandedNavButtonGap,
    expandedNavButtonHorizontalPadding,
    expandedNavButtonVerticalPadding,
    expandedSidebarPadding,
    expandedSidebarHeaderGap,
    expandedSidebarTitleSpacing,
    expandedSidebarLogoTitleGap,
    expandedSidebarSplashRadius,
    optionsPanelDefaultWidth,
    optionsPanelMinWidth,
    optionsPanelMaxWidth,
    toolbarHeight,
    toolbarHorizontalPadding,
    toolbarIconButtonSize,
    toolbarIconSize,
    toolbarPillIconSize,
    panelGap,
    panelRadius,
    controlRadius,
    stagePadding,
    heroIconSize,
    heroButtonHeight,
    heroButtonMinWidth,
    heroTitleScale,
    gridStep,
    paneHeaderTopPadding,
    paneHeaderBottomPadding,
    paneHeaderTitleSize,
    sidebarSectionGap,
    sidebarRowGap,
    sidebarCompactGap,
    sidebarCompactRowGap,
    sidebarControlGap,
    sidebarOptionsGroupGap,
    sidebarOptionsSubgroupGap,
    sidebarInsetPadding,
    sidebarInsetRadius,
    sidebarContentHorizontalPadding,
    sidebarContentHorizontalPaddingCompact,
    sidebarHeaderContentGap,
    sidebarRailItemGap,
    sidebarRailItemVerticalPadding,
    sidebarLabelWidth,
    sidebarStackBreakpoint,
    sidebarCompactWidthBreakpoint,
    sidebarControlMinWidth,
    sidebarControlMaxWidth,
    sidebarControlHeightMac,
    sidebarControlHeightDefault,
    sidebarCompactButtonHeight,
    sidebarIconSmall,
    sidebarIconMedium,
    sidebarActionIconSize,
    autoCollapseOptions,
    autoCompactRail,
  ]);
}

class ResponsiveShellScope extends InheritedWidget {
  const ResponsiveShellScope({
    super.key,
    required this.metrics,
    required super.child,
  });

  final ShellResponsiveMetrics metrics;

  static ShellResponsiveMetrics? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ResponsiveShellScope>()
        ?.metrics;
  }

  static ShellResponsiveMetrics of(BuildContext context) {
    final metrics = maybeOf(context);
    assert(metrics != null, 'ResponsiveShellScope not found in context');
    return metrics!;
  }

  @override
  bool updateShouldNotify(ResponsiveShellScope oldWidget) {
    return oldWidget.metrics != metrics;
  }
}

extension ShellResponsiveContextX on BuildContext {
  ShellResponsiveMetrics get shellMetrics => ResponsiveShellScope.of(this);
  ShellResponsiveMetrics? get shellMetricsOrNull =>
      ResponsiveShellScope.maybeOf(this);
  ShellDensity get shellDensity => shellMetrics.density;
  double get shellScale => shellMetrics.scale;
}
