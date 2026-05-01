import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShellResponsiveMetrics.fromSize', () {
    test('comfortable density at >= 1400px', () {
      final m = ShellResponsiveMetrics.fromSize(const Size(1500, 900));
      expect(m.density, ShellDensity.comfortable);
      expect(m.scale, 1.0);
      expect(m.toolbarHeight, 50);
      expect(m.heroIconSize, 64);
      expect(m.railButtonSize, 40);
      expect(m.autoCollapseOptions, isFalse);
      expect(m.autoCompactRail, isFalse);
    });

    test('compact density at 1200-1399px', () {
      final m = ShellResponsiveMetrics.fromSize(const Size(1300, 800));
      expect(m.density, ShellDensity.compact);
      expect(m.scale, 0.92);
      expect(m.autoCollapseOptions, isFalse);
      expect(m.autoCompactRail, isFalse);
    });

    test('dense density at 1000-1199px shrinks chrome', () {
      final comfortable =
          ShellResponsiveMetrics.fromSize(const Size(1500, 900));
      final dense = ShellResponsiveMetrics.fromSize(const Size(1100, 800));
      expect(dense.density, ShellDensity.dense);
      expect(dense.scale, 0.84);
      expect(dense.toolbarHeight, lessThan(comfortable.toolbarHeight));
      expect(dense.heroIconSize, lessThan(comfortable.heroIconSize));
      expect(dense.railButtonSize, lessThan(comfortable.railButtonSize));
      expect(dense.optionsPanelDefaultWidth,
          lessThan(comfortable.optionsPanelDefaultWidth));
      expect(dense.autoCompactRail, isFalse);
      expect(dense.autoCollapseOptions, isFalse);
    });

    test('minimal density at < 1000px auto-collapses options', () {
      final m = ShellResponsiveMetrics.fromSize(const Size(900, 800));
      expect(m.density, ShellDensity.minimal);
      expect(m.scale, 0.78);
      expect(m.autoCollapseOptions, isTrue);
      expect(m.autoCompactRail, isTrue);
    });

    test('minimums respected at minimal density', () {
      final m = ShellResponsiveMetrics.fromSize(const Size(800, 700));
      expect(m.heroButtonHeight, greaterThanOrEqualTo(34));
      expect(m.railButtonSize, greaterThanOrEqualTo(34));
      expect(m.panelRadius, greaterThanOrEqualTo(8));
      expect(m.stagePadding, greaterThanOrEqualTo(6));
    });

    test('value equality holds for same input size', () {
      final a = ShellResponsiveMetrics.fromSize(const Size(1300, 800));
      final b = ShellResponsiveMetrics.fromSize(const Size(1300, 800));
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('left rail expanded min/max + font sizes + help-menu fallback shrink',
        () {
      final comfortable =
          ShellResponsiveMetrics.fromSize(const Size(1500, 900));
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      expect(minimal.leftRailExpandedMinWidth,
          lessThan(comfortable.leftRailExpandedMinWidth));
      expect(minimal.leftRailExpandedMaxWidth,
          lessThan(comfortable.leftRailExpandedMaxWidth));
      expect(minimal.expandedSidebarTitleFontSize,
          lessThan(comfortable.expandedSidebarTitleFontSize));
      expect(minimal.expandedSidebarSectionFontSize,
          lessThanOrEqualTo(comfortable.expandedSidebarSectionFontSize));
      expect(minimal.sidebarHelpMenuIconSize,
          lessThan(comfortable.sidebarHelpMenuIconSize));
      expect(minimal.sidebarHelpMenuFallbackInset,
          lessThan(comfortable.sidebarHelpMenuFallbackInset));
      // Hard minimums.
      expect(minimal.leftRailExpandedMinWidth, greaterThanOrEqualTo(160));
      expect(minimal.expandedSidebarTitleFontSize, greaterThanOrEqualTo(13));
      expect(minimal.expandedSidebarSectionFontSize, greaterThanOrEqualTo(11));
    });

    test('rail chrome shrinks with density and respects minimums', () {
      final comfortable =
          ShellResponsiveMetrics.fromSize(const Size(1500, 900));
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      // Width tiers.
      expect(minimal.railWidth, lessThan(comfortable.railWidth));
      expect(minimal.railCompactWidth, lessThan(comfortable.railCompactWidth));
      expect(minimal.railButtonSize, lessThan(comfortable.railButtonSize));
      expect(minimal.railIconSize, lessThan(comfortable.railIconSize));
      // Compact paddings + gaps.
      expect(minimal.railTopPaddingCompact,
          lessThan(comfortable.railTopPaddingCompact));
      expect(minimal.railBottomPaddingCompact,
          lessThan(comfortable.railBottomPaddingCompact));
      expect(
          minimal.railUtilityGap, lessThan(comfortable.railUtilityGap));
      // Hard minimums.
      expect(minimal.railCompactWidth, greaterThanOrEqualTo(46));
      expect(minimal.railButtonSize, greaterThanOrEqualTo(34));
      expect(minimal.railIconSize, greaterThanOrEqualTo(20));
      expect(minimal.railTopPaddingCompact, greaterThanOrEqualTo(6));
      expect(minimal.railBottomPaddingCompact, greaterThanOrEqualTo(2));
    });

    test('expanded sidebar chrome shrinks with density', () {
      final comfortable =
          ShellResponsiveMetrics.fromSize(const Size(1500, 900));
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      expect(minimal.expandedNavButtonHeight,
          lessThan(comfortable.expandedNavButtonHeight));
      expect(minimal.expandedNavButtonIconSize,
          lessThan(comfortable.expandedNavButtonIconSize));
      expect(minimal.expandedNavButtonGap,
          lessThan(comfortable.expandedNavButtonGap));
      expect(minimal.expandedSidebarPadding,
          lessThan(comfortable.expandedSidebarPadding));
      expect(minimal.expandedSidebarHeaderGap,
          lessThan(comfortable.expandedSidebarHeaderGap));
    });

    test('sidebar metrics shrink with density and respect minimums', () {
      final comfortable =
          ShellResponsiveMetrics.fromSize(const Size(1500, 900));
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      expect(minimal.sidebarSectionGap,
          lessThan(comfortable.sidebarSectionGap));
      expect(minimal.sidebarRowGap, lessThan(comfortable.sidebarRowGap));
      expect(minimal.sidebarLabelWidth,
          lessThan(comfortable.sidebarLabelWidth));
      expect(minimal.sidebarControlMinWidth,
          lessThan(comfortable.sidebarControlMinWidth));
      expect(minimal.sidebarControlMaxWidth,
          lessThan(comfortable.sidebarControlMaxWidth));
      // Minimums.
      expect(minimal.sidebarSectionGap, greaterThanOrEqualTo(8));
      expect(minimal.sidebarRowGap, greaterThanOrEqualTo(5));
      expect(minimal.sidebarLabelWidth, greaterThanOrEqualTo(128));
      expect(minimal.sidebarControlMinWidth, greaterThanOrEqualTo(160));
      expect(minimal.sidebarControlHeightDefault, greaterThanOrEqualTo(28));
      expect(minimal.sidebarCompactButtonHeight, greaterThanOrEqualTo(28));
    });

    test('timeline structural metrics shrink with density and clamp minimums',
        () {
      final comfortable =
          ShellResponsiveMetrics.fromSize(const Size(1500, 900));
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      // Heights and widths shrink.
      expect(minimal.timelineRulerHeight,
          lessThan(comfortable.timelineRulerHeight));
      expect(minimal.timelineLaneHeight,
          lessThan(comfortable.timelineLaneHeight));
      expect(minimal.timelineTrackHeaderWidth,
          lessThan(comfortable.timelineTrackHeaderWidth));
      expect(minimal.timelineHeaderMinHeight,
          lessThan(comfortable.timelineHeaderMinHeight));
      expect(minimal.timelineTransportMinHeight,
          lessThan(comfortable.timelineTransportMinHeight));
      expect(minimal.timelineZoomSliderMinWidth,
          lessThan(comfortable.timelineZoomSliderMinWidth));
      expect(minimal.timelineZoomSliderMaxWidth,
          lessThan(comfortable.timelineZoomSliderMaxWidth));
      expect(minimal.timelineRulerLabelFontSize,
          lessThan(comfortable.timelineRulerLabelFontSize));
      expect(minimal.timelinePlayheadCapWidth,
          lessThan(comfortable.timelinePlayheadCapWidth));
      // Hard minimums respected.
      expect(minimal.timelineHeaderMinHeight, greaterThanOrEqualTo(32));
      expect(minimal.timelineTransportMinHeight, greaterThanOrEqualTo(32));
      expect(minimal.timelineRulerHeight, greaterThanOrEqualTo(24));
      expect(minimal.timelineLaneHeight, greaterThanOrEqualTo(34));
      expect(minimal.timelineTrackHeaderWidth, greaterThanOrEqualTo(56));
      expect(minimal.timelineToolbarChipMinHeight, greaterThanOrEqualTo(28));
      expect(minimal.timelineToolbarChipIconSize, greaterThanOrEqualTo(13));
      expect(minimal.timelineCloseIconSize, greaterThanOrEqualTo(13));
      expect(minimal.timelineIconButtonSize, greaterThanOrEqualTo(28));
      expect(minimal.timelineRulerLabelFontSize, greaterThanOrEqualTo(9.5));
      expect(minimal.timelineZoomSliderMinWidth, greaterThanOrEqualTo(80));
      expect(minimal.timelineZoomSliderMaxWidth, greaterThanOrEqualTo(140));
      expect(minimal.timelinePlayheadCapWidth, greaterThanOrEqualTo(6));
      expect(minimal.timelinePlayheadCapHeight, greaterThanOrEqualTo(4));
    });

    test('density boundary is half-open (>= breakpoint -> tier above)', () {
      expect(ShellResponsiveMetrics.densityForWidth(1400),
          ShellDensity.comfortable);
      expect(ShellResponsiveMetrics.densityForWidth(1200),
          ShellDensity.compact);
      expect(ShellResponsiveMetrics.densityForWidth(1199.99),
          ShellDensity.dense);
      expect(ShellResponsiveMetrics.densityForWidth(1000),
          ShellDensity.dense);
      expect(ShellResponsiveMetrics.densityForWidth(999),
          ShellDensity.minimal);
    });
  });

  group('ResponsiveShellScope', () {
    testWidgets('exposes metrics via context extension', (tester) async {
      final metrics = ShellResponsiveMetrics.fromSize(const Size(1100, 800));
      ShellResponsiveMetrics? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: ResponsiveShellScope(
            metrics: metrics,
            child: Builder(
              builder: (context) {
                captured = context.shellMetrics;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(captured, equals(metrics));
      expect(captured?.density, ShellDensity.dense);
    });

    testWidgets('maybeOf returns null without scope', (tester) async {
      ShellResponsiveMetrics? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context.shellMetricsOrNull;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, isNull);
    });
  });
}
