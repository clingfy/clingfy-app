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
    required this.leftRailExpandedMinWidth,
    required this.leftRailExpandedMaxWidth,
    required this.expandedSidebarTitleFontSize,
    required this.expandedSidebarSectionFontSize,
    required this.expandedSidebarUtilityGap,
    required this.sidebarHelpMenuIconSize,
    required this.sidebarHelpMenuIconGap,
    required this.sidebarHelpMenuFallbackInset,
    required this.sidebarHelpMenuFallbackSize,
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
    required this.timelineShellGap,
    required this.timelineShellPaddingX,
    required this.timelineShellPaddingY,
    required this.timelineHeaderMinHeight,
    required this.timelineTransportMinHeight,
    required this.timelineChromePaddingX,
    required this.timelineChromePaddingY,
    required this.timelineControlGap,
    required this.timelineSectionGap,
    required this.timelineRulerHeight,
    required this.timelineLaneHeight,
    required this.timelineLaneGap,
    required this.timelineTrackHeaderWidth,
    required this.timelineTrackHeaderPaddingX,
    required this.timelineLaneHeaderIconSize,
    required this.timelineLaneHeaderIconTextGap,
    required this.timelineLaneHeaderTextScale,
    required this.timelineToolbarChipMinHeight,
    required this.timelineToolbarChipPaddingX,
    required this.timelineToolbarChipPaddingY,
    required this.timelineToolbarChipIconSize,
    required this.timelineToolbarChipTextScale,
    required this.timelineCloseIconSize,
    required this.timelineIconButtonSize,
    required this.timelineIconButtonIconSize,
    required this.timelineButtonMinHeight,
    required this.timelineZoomSliderMinWidth,
    required this.timelineZoomSliderMaxWidth,
    required this.timelineZoomSliderWidthFactor,
    required this.timelineTimeTextScale,
    required this.timelineModeTextScale,
    required this.timelineHideZoomLabelBelowWidth,
    required this.timelineCompactTransportBelowWidth,
    required this.timelineRulerLabelFontSize,
    required this.timelineRulerMajorTickHeight,
    required this.timelineRulerMinorTickHeight,
    required this.timelineRulerMajorStrokeWidth,
    required this.timelineRulerMinorStrokeWidth,
    required this.timelineRulerLabelTop,
    required this.timelineRulerMinMajorTickSpacing,
    required this.timelinePlayheadHoverWidth,
    required this.timelinePlayheadLineWidth,
    required this.timelinePlayheadCapWidth,
    required this.timelinePlayheadCapHeight,
    required this.timelinePlayheadCapRadius,
    required this.timelinePlayheadCapTop,
    required this.timelinePlayheadShadowBlur,
    required this.timelineMarkerPinUp,
    required this.timelineMarkerPinDown,
    required this.timelineMarkerStrokeWidth,
    required this.timelineMarkerMaxVisiblePins,
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
  final double leftRailExpandedMinWidth;
  final double leftRailExpandedMaxWidth;
  final double expandedSidebarTitleFontSize;
  final double expandedSidebarSectionFontSize;
  final double expandedSidebarUtilityGap;
  final double sidebarHelpMenuIconSize;
  final double sidebarHelpMenuIconGap;
  final double sidebarHelpMenuFallbackInset;
  final double sidebarHelpMenuFallbackSize;

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

  // Timeline chrome / structural metrics.
  final double timelineShellGap;
  final double timelineShellPaddingX;
  final double timelineShellPaddingY;
  final double timelineHeaderMinHeight;
  final double timelineTransportMinHeight;
  final double timelineChromePaddingX;
  final double timelineChromePaddingY;
  final double timelineControlGap;
  final double timelineSectionGap;

  // Timeline viewport.
  final double timelineRulerHeight;
  final double timelineLaneHeight;
  final double timelineLaneGap;
  final double timelineTrackHeaderWidth;
  final double timelineTrackHeaderPaddingX;
  final double timelineLaneHeaderIconSize;
  final double timelineLaneHeaderIconTextGap;
  final double timelineLaneHeaderTextScale;

  // Timeline header/transport controls.
  final double timelineToolbarChipMinHeight;
  final double timelineToolbarChipPaddingX;
  final double timelineToolbarChipPaddingY;
  final double timelineToolbarChipIconSize;
  final double timelineToolbarChipTextScale;
  final double timelineCloseIconSize;
  final double timelineIconButtonSize;
  final double timelineIconButtonIconSize;
  final double timelineButtonMinHeight;

  // Transport.
  final double timelineZoomSliderMinWidth;
  final double timelineZoomSliderMaxWidth;
  final double timelineZoomSliderWidthFactor;
  final double timelineTimeTextScale;
  final double timelineModeTextScale;
  final double timelineHideZoomLabelBelowWidth;
  final double timelineCompactTransportBelowWidth;

  // Ruler painter.
  final double timelineRulerLabelFontSize;
  final double timelineRulerMajorTickHeight;
  final double timelineRulerMinorTickHeight;
  final double timelineRulerMajorStrokeWidth;
  final double timelineRulerMinorStrokeWidth;
  final double timelineRulerLabelTop;
  final double timelineRulerMinMajorTickSpacing;

  // Playhead.
  final double timelinePlayheadHoverWidth;
  final double timelinePlayheadLineWidth;
  final double timelinePlayheadCapWidth;
  final double timelinePlayheadCapHeight;
  final double timelinePlayheadCapRadius;
  final double timelinePlayheadCapTop;
  final double timelinePlayheadShadowBlur;

  // Markers.
  final double timelineMarkerPinUp;
  final double timelineMarkerPinDown;
  final double timelineMarkerStrokeWidth;
  final int timelineMarkerMaxVisiblePins;

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
      leftRailExpandedMinWidth: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 196,
          compact: 184,
          dense: 172,
          minimal: 164,
        ),
        160,
      ),
      leftRailExpandedMaxWidth: _atLeast(
        _lerpForDensity(
          density,
          comfortable: 260,
          compact: 244,
          dense: 224,
          minimal: 204,
        ),
        180,
      ),
      expandedSidebarTitleFontSize: _atLeast(15 * scale, 13),
      expandedSidebarSectionFontSize: _atLeast(12 * scale, 11),
      expandedSidebarUtilityGap: _atLeast(8 * scale, 4),
      sidebarHelpMenuIconSize: _atLeast(18 * scale, 14),
      sidebarHelpMenuIconGap: _atLeast(10 * scale, 6),
      sidebarHelpMenuFallbackInset: _atLeast(72 * scale, 48),
      sidebarHelpMenuFallbackSize: _atLeast(40 * scale, 32),
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
      // Timeline structural metrics. Comfortable values mirror existing
      // appEditorChrome / appSpacing values used today; smaller densities
      // shrink toward hard minimums.
      timelineShellGap: _atLeast(6 * scale, 3),
      timelineShellPaddingX: _atLeast(0 * scale, 0),
      timelineShellPaddingY: _atLeast(0 * scale, 0),
      timelineHeaderMinHeight: _atLeast(40 * scale, 32),
      timelineTransportMinHeight: _atLeast(40 * scale, 32),
      timelineChromePaddingX: _atLeast(12 * scale, 8),
      timelineChromePaddingY: _atLeast(8 * scale, 5),
      timelineControlGap: _atLeast(6 * scale, 4),
      timelineSectionGap: _atLeast(12 * scale, 8),
      timelineRulerHeight: _atLeast(28 * scale, 24),
      timelineLaneHeight: _atLeast(42 * scale, 34),
      timelineLaneGap: _atLeast(6 * scale, 3),
      timelineTrackHeaderWidth: _atLeast(92 * scale, 56),
      timelineTrackHeaderPaddingX: _atLeast(4 * scale, 3),
      timelineLaneHeaderIconSize: _atLeast(16 * scale, 13),
      timelineLaneHeaderIconTextGap: _atLeast(4 * scale, 3),
      timelineLaneHeaderTextScale: _clampDouble(
        0.86 + (scale - 0.78) * 0.6,
        0.86,
        1.0,
      ),
      timelineToolbarChipMinHeight: _atLeast(34 * scale, 28),
      timelineToolbarChipPaddingX: _atLeast(8 * scale, 5),
      timelineToolbarChipPaddingY: _atLeast(4 * scale, 3),
      timelineToolbarChipIconSize: _atLeast(16 * scale, 13),
      timelineToolbarChipTextScale: _clampDouble(
        0.86 + (scale - 0.78) * 0.6,
        0.86,
        1.0,
      ),
      timelineCloseIconSize: _atLeast(17 * scale, 13),
      timelineIconButtonSize: _atLeast(32 * scale, 28),
      timelineIconButtonIconSize: _atLeast(18 * scale, 14),
      timelineButtonMinHeight: _atLeast(32 * scale, 28),
      timelineZoomSliderMinWidth: _atLeast(120 * scale, 80),
      timelineZoomSliderMaxWidth: _atLeast(220 * scale, 140),
      timelineZoomSliderWidthFactor: 0.20,
      timelineTimeTextScale: _clampDouble(
        0.86 + (scale - 0.78) * 0.6,
        0.86,
        1.0,
      ),
      timelineModeTextScale: _clampDouble(
        0.86 + (scale - 0.78) * 0.6,
        0.86,
        1.0,
      ),
      timelineHideZoomLabelBelowWidth: _atLeast(560 * scale, 420),
      timelineCompactTransportBelowWidth: _atLeast(640 * scale, 480),
      timelineRulerLabelFontSize: _atLeast(11 * scale, 9.5),
      timelineRulerMajorTickHeight: _atLeast(15 * scale, 9),
      timelineRulerMinorTickHeight: _atLeast(8 * scale, 5),
      timelineRulerMajorStrokeWidth: 1.2,
      timelineRulerMinorStrokeWidth: 1.0,
      timelineRulerLabelTop: _atLeast(6 * scale, 4),
      timelineRulerMinMajorTickSpacing: _atLeast(110 * scale, 72),
      timelinePlayheadHoverWidth: _atLeast(1.5 * scale, 1.0),
      timelinePlayheadLineWidth: _atLeast(2 * scale, 1.5),
      timelinePlayheadCapWidth: _atLeast(8 * scale, 6),
      timelinePlayheadCapHeight: _atLeast(6 * scale, 4),
      timelinePlayheadCapRadius: _atLeast(3 * scale, 2),
      timelinePlayheadCapTop: _atLeast(1 * scale, 0.5),
      timelinePlayheadShadowBlur: _atLeast(5 * scale, 3),
      timelineMarkerPinUp: _atLeast(8 * scale, 5),
      timelineMarkerPinDown: _atLeast(5 * scale, 3),
      timelineMarkerStrokeWidth: 1.25,
      timelineMarkerMaxVisiblePins: density == ShellDensity.minimal
          ? 6
          : density == ShellDensity.dense
          ? 7
          : 8,
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
        other.leftRailExpandedMinWidth == leftRailExpandedMinWidth &&
        other.leftRailExpandedMaxWidth == leftRailExpandedMaxWidth &&
        other.expandedSidebarTitleFontSize == expandedSidebarTitleFontSize &&
        other.expandedSidebarSectionFontSize ==
            expandedSidebarSectionFontSize &&
        other.expandedSidebarUtilityGap == expandedSidebarUtilityGap &&
        other.sidebarHelpMenuIconSize == sidebarHelpMenuIconSize &&
        other.sidebarHelpMenuIconGap == sidebarHelpMenuIconGap &&
        other.sidebarHelpMenuFallbackInset == sidebarHelpMenuFallbackInset &&
        other.sidebarHelpMenuFallbackSize == sidebarHelpMenuFallbackSize &&
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
        other.sidebarCompactWidthBreakpoint == sidebarCompactWidthBreakpoint &&
        other.sidebarControlMinWidth == sidebarControlMinWidth &&
        other.sidebarControlMaxWidth == sidebarControlMaxWidth &&
        other.sidebarControlHeightMac == sidebarControlHeightMac &&
        other.sidebarControlHeightDefault == sidebarControlHeightDefault &&
        other.sidebarCompactButtonHeight == sidebarCompactButtonHeight &&
        other.sidebarIconSmall == sidebarIconSmall &&
        other.sidebarIconMedium == sidebarIconMedium &&
        other.sidebarActionIconSize == sidebarActionIconSize &&
        other.timelineShellGap == timelineShellGap &&
        other.timelineShellPaddingX == timelineShellPaddingX &&
        other.timelineShellPaddingY == timelineShellPaddingY &&
        other.timelineHeaderMinHeight == timelineHeaderMinHeight &&
        other.timelineTransportMinHeight == timelineTransportMinHeight &&
        other.timelineChromePaddingX == timelineChromePaddingX &&
        other.timelineChromePaddingY == timelineChromePaddingY &&
        other.timelineControlGap == timelineControlGap &&
        other.timelineSectionGap == timelineSectionGap &&
        other.timelineRulerHeight == timelineRulerHeight &&
        other.timelineLaneHeight == timelineLaneHeight &&
        other.timelineLaneGap == timelineLaneGap &&
        other.timelineTrackHeaderWidth == timelineTrackHeaderWidth &&
        other.timelineTrackHeaderPaddingX == timelineTrackHeaderPaddingX &&
        other.timelineLaneHeaderIconSize == timelineLaneHeaderIconSize &&
        other.timelineLaneHeaderIconTextGap == timelineLaneHeaderIconTextGap &&
        other.timelineLaneHeaderTextScale == timelineLaneHeaderTextScale &&
        other.timelineToolbarChipMinHeight == timelineToolbarChipMinHeight &&
        other.timelineToolbarChipPaddingX == timelineToolbarChipPaddingX &&
        other.timelineToolbarChipPaddingY == timelineToolbarChipPaddingY &&
        other.timelineToolbarChipIconSize == timelineToolbarChipIconSize &&
        other.timelineToolbarChipTextScale == timelineToolbarChipTextScale &&
        other.timelineCloseIconSize == timelineCloseIconSize &&
        other.timelineIconButtonSize == timelineIconButtonSize &&
        other.timelineIconButtonIconSize == timelineIconButtonIconSize &&
        other.timelineButtonMinHeight == timelineButtonMinHeight &&
        other.timelineZoomSliderMinWidth == timelineZoomSliderMinWidth &&
        other.timelineZoomSliderMaxWidth == timelineZoomSliderMaxWidth &&
        other.timelineZoomSliderWidthFactor == timelineZoomSliderWidthFactor &&
        other.timelineTimeTextScale == timelineTimeTextScale &&
        other.timelineModeTextScale == timelineModeTextScale &&
        other.timelineHideZoomLabelBelowWidth ==
            timelineHideZoomLabelBelowWidth &&
        other.timelineCompactTransportBelowWidth ==
            timelineCompactTransportBelowWidth &&
        other.timelineRulerLabelFontSize == timelineRulerLabelFontSize &&
        other.timelineRulerMajorTickHeight == timelineRulerMajorTickHeight &&
        other.timelineRulerMinorTickHeight == timelineRulerMinorTickHeight &&
        other.timelineRulerMajorStrokeWidth == timelineRulerMajorStrokeWidth &&
        other.timelineRulerMinorStrokeWidth == timelineRulerMinorStrokeWidth &&
        other.timelineRulerLabelTop == timelineRulerLabelTop &&
        other.timelineRulerMinMajorTickSpacing ==
            timelineRulerMinMajorTickSpacing &&
        other.timelinePlayheadHoverWidth == timelinePlayheadHoverWidth &&
        other.timelinePlayheadLineWidth == timelinePlayheadLineWidth &&
        other.timelinePlayheadCapWidth == timelinePlayheadCapWidth &&
        other.timelinePlayheadCapHeight == timelinePlayheadCapHeight &&
        other.timelinePlayheadCapRadius == timelinePlayheadCapRadius &&
        other.timelinePlayheadCapTop == timelinePlayheadCapTop &&
        other.timelinePlayheadShadowBlur == timelinePlayheadShadowBlur &&
        other.timelineMarkerPinUp == timelineMarkerPinUp &&
        other.timelineMarkerPinDown == timelineMarkerPinDown &&
        other.timelineMarkerStrokeWidth == timelineMarkerStrokeWidth &&
        other.timelineMarkerMaxVisiblePins == timelineMarkerMaxVisiblePins &&
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
    leftRailExpandedMinWidth,
    leftRailExpandedMaxWidth,
    expandedSidebarTitleFontSize,
    expandedSidebarSectionFontSize,
    expandedSidebarUtilityGap,
    sidebarHelpMenuIconSize,
    sidebarHelpMenuIconGap,
    sidebarHelpMenuFallbackInset,
    sidebarHelpMenuFallbackSize,
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
    timelineShellGap,
    timelineShellPaddingX,
    timelineShellPaddingY,
    timelineHeaderMinHeight,
    timelineTransportMinHeight,
    timelineChromePaddingX,
    timelineChromePaddingY,
    timelineControlGap,
    timelineSectionGap,
    timelineRulerHeight,
    timelineLaneHeight,
    timelineLaneGap,
    timelineTrackHeaderWidth,
    timelineTrackHeaderPaddingX,
    timelineLaneHeaderIconSize,
    timelineLaneHeaderIconTextGap,
    timelineLaneHeaderTextScale,
    timelineToolbarChipMinHeight,
    timelineToolbarChipPaddingX,
    timelineToolbarChipPaddingY,
    timelineToolbarChipIconSize,
    timelineToolbarChipTextScale,
    timelineCloseIconSize,
    timelineIconButtonSize,
    timelineIconButtonIconSize,
    timelineButtonMinHeight,
    timelineZoomSliderMinWidth,
    timelineZoomSliderMaxWidth,
    timelineZoomSliderWidthFactor,
    timelineTimeTextScale,
    timelineModeTextScale,
    timelineHideZoomLabelBelowWidth,
    timelineCompactTransportBelowWidth,
    timelineRulerLabelFontSize,
    timelineRulerMajorTickHeight,
    timelineRulerMinorTickHeight,
    timelineRulerMajorStrokeWidth,
    timelineRulerMinorStrokeWidth,
    timelineRulerLabelTop,
    timelineRulerMinMajorTickSpacing,
    timelinePlayheadHoverWidth,
    timelinePlayheadLineWidth,
    timelinePlayheadCapWidth,
    timelinePlayheadCapHeight,
    timelinePlayheadCapRadius,
    timelinePlayheadCapTop,
    timelinePlayheadShadowBlur,
    timelineMarkerPinUp,
    timelineMarkerPinDown,
    timelineMarkerStrokeWidth,
    timelineMarkerMaxVisiblePins,
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
