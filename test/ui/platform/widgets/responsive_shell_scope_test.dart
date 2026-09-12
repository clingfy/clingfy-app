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
      final comfortable = ShellResponsiveMetrics.fromSize(
        const Size(1500, 900),
      );
      final dense = ShellResponsiveMetrics.fromSize(const Size(1100, 800));
      expect(dense.density, ShellDensity.dense);
      expect(dense.scale, 0.84);
      expect(dense.toolbarHeight, lessThan(comfortable.toolbarHeight));
      expect(dense.heroIconSize, lessThan(comfortable.heroIconSize));
      expect(dense.railButtonSize, lessThan(comfortable.railButtonSize));
      expect(
        dense.optionsPanelDefaultWidth,
        lessThan(comfortable.optionsPanelDefaultWidth),
      );
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

    test(
      'left rail expanded min/max + font sizes + help-menu fallback shrink',
      () {
        final comfortable = ShellResponsiveMetrics.fromSize(
          const Size(1500, 900),
        );
        final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
        expect(
          minimal.leftRailExpandedMinWidth,
          lessThan(comfortable.leftRailExpandedMinWidth),
        );
        expect(
          minimal.leftRailExpandedMaxWidth,
          lessThan(comfortable.leftRailExpandedMaxWidth),
        );
        expect(
          minimal.expandedSidebarTitleFontSize,
          lessThan(comfortable.expandedSidebarTitleFontSize),
        );
        expect(
          minimal.expandedSidebarSectionFontSize,
          lessThanOrEqualTo(comfortable.expandedSidebarSectionFontSize),
        );
        expect(
          minimal.sidebarHelpMenuIconSize,
          lessThan(comfortable.sidebarHelpMenuIconSize),
        );
        expect(
          minimal.sidebarHelpMenuFallbackInset,
          lessThan(comfortable.sidebarHelpMenuFallbackInset),
        );
        // Hard minimums.
        expect(minimal.leftRailExpandedMinWidth, greaterThanOrEqualTo(160));
        expect(minimal.expandedSidebarTitleFontSize, greaterThanOrEqualTo(13));
        expect(
          minimal.expandedSidebarSectionFontSize,
          greaterThanOrEqualTo(11),
        );
      },
    );

    test('rail chrome shrinks with density and respects minimums', () {
      final comfortable = ShellResponsiveMetrics.fromSize(
        const Size(1500, 900),
      );
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      // Width tiers.
      expect(minimal.railWidth, lessThan(comfortable.railWidth));
      expect(minimal.railCompactWidth, lessThan(comfortable.railCompactWidth));
      expect(minimal.railButtonSize, lessThan(comfortable.railButtonSize));
      expect(minimal.railIconSize, lessThan(comfortable.railIconSize));
      // Compact paddings + gaps.
      expect(
        minimal.railTopPaddingCompact,
        lessThan(comfortable.railTopPaddingCompact),
      );
      expect(
        minimal.railBottomPaddingCompact,
        lessThan(comfortable.railBottomPaddingCompact),
      );
      expect(minimal.railUtilityGap, lessThan(comfortable.railUtilityGap));
      // Hard minimums.
      expect(minimal.railCompactWidth, greaterThanOrEqualTo(46));
      expect(minimal.railButtonSize, greaterThanOrEqualTo(34));
      expect(minimal.railIconSize, greaterThanOrEqualTo(20));
      expect(minimal.railTopPaddingCompact, greaterThanOrEqualTo(6));
      expect(minimal.railBottomPaddingCompact, greaterThanOrEqualTo(2));
    });

    test('expanded sidebar chrome shrinks with density', () {
      final comfortable = ShellResponsiveMetrics.fromSize(
        const Size(1500, 900),
      );
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      expect(
        minimal.expandedNavButtonHeight,
        lessThan(comfortable.expandedNavButtonHeight),
      );
      expect(
        minimal.expandedNavButtonIconSize,
        lessThan(comfortable.expandedNavButtonIconSize),
      );
      expect(
        minimal.expandedNavButtonGap,
        lessThan(comfortable.expandedNavButtonGap),
      );
      expect(
        minimal.expandedSidebarPadding,
        lessThan(comfortable.expandedSidebarPadding),
      );
      expect(
        minimal.expandedSidebarHeaderGap,
        lessThan(comfortable.expandedSidebarHeaderGap),
      );
    });

    test('sidebar metrics shrink with density and respect minimums', () {
      final comfortable = ShellResponsiveMetrics.fromSize(
        const Size(1500, 900),
      );
      final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
      expect(
        minimal.sidebarSectionGap,
        lessThan(comfortable.sidebarSectionGap),
      );
      expect(minimal.sidebarRowGap, lessThan(comfortable.sidebarRowGap));
      expect(
        minimal.sidebarLabelWidth,
        lessThan(comfortable.sidebarLabelWidth),
      );
      expect(
        minimal.sidebarControlMinWidth,
        lessThan(comfortable.sidebarControlMinWidth),
      );
      expect(
        minimal.sidebarControlMaxWidth,
        lessThan(comfortable.sidebarControlMaxWidth),
      );
      // Minimums.
      expect(minimal.sidebarSectionGap, greaterThanOrEqualTo(8));
      expect(minimal.sidebarRowGap, greaterThanOrEqualTo(5));
      expect(minimal.sidebarLabelWidth, greaterThanOrEqualTo(128));
      expect(minimal.sidebarControlMinWidth, greaterThanOrEqualTo(160));
      expect(minimal.sidebarControlHeightDefault, greaterThanOrEqualTo(28));
      expect(minimal.sidebarCompactButtonHeight, greaterThanOrEqualTo(28));
    });

    test(
      'timeline structural metrics shrink with density and clamp minimums',
      () {
        final comfortable = ShellResponsiveMetrics.fromSize(
          const Size(1500, 900),
        );
        final minimal = ShellResponsiveMetrics.fromSize(const Size(800, 760));
        // Heights and widths shrink.
        expect(
          minimal.timelineRulerHeight,
          lessThan(comfortable.timelineRulerHeight),
        );
        expect(
          minimal.timelineLaneHeight,
          lessThan(comfortable.timelineLaneHeight),
        );
        expect(
          minimal.timelineTrackHeaderWidth,
          lessThan(comfortable.timelineTrackHeaderWidth),
        );
        expect(
          minimal.timelineHeaderMinHeight,
          lessThan(comfortable.timelineHeaderMinHeight),
        );
        expect(
          minimal.timelineTransportMinHeight,
          lessThan(comfortable.timelineTransportMinHeight),
        );
        expect(
          minimal.timelineZoomSliderMinWidth,
          lessThan(comfortable.timelineZoomSliderMinWidth),
        );
        expect(
          minimal.timelineZoomSliderMaxWidth,
          lessThan(comfortable.timelineZoomSliderMaxWidth),
        );
        expect(
          minimal.timelineRulerLabelFontSize,
          lessThan(comfortable.timelineRulerLabelFontSize),
        );
        expect(
          minimal.timelinePlayheadCapWidth,
          lessThan(comfortable.timelinePlayheadCapWidth),
        );
        // Hard minimums respected.
        expect(minimal.timelineHeaderMinHeight, greaterThanOrEqualTo(32));
        expect(minimal.timelineTransportMinHeight, greaterThanOrEqualTo(32));
        expect(minimal.timelineRulerHeight, greaterThanOrEqualTo(24));
        expect(minimal.timelineLaneHeight, greaterThanOrEqualTo(34));
        expect(minimal.timelineTrackHeaderWidth, greaterThanOrEqualTo(56));
        expect(minimal.timelineToolbarChipMinHeight, greaterThanOrEqualTo(28));
        expect(minimal.timelineToolbarChipIconSize, greaterThanOrEqualTo(13));
        expect(minimal.timelineIconButtonSize, greaterThanOrEqualTo(28));
        expect(minimal.timelineRulerLabelFontSize, greaterThanOrEqualTo(9.5));
        expect(minimal.timelineZoomSliderMinWidth, greaterThanOrEqualTo(80));
        expect(minimal.timelineZoomSliderMaxWidth, greaterThanOrEqualTo(140));
        expect(minimal.timelinePlayheadCapWidth, greaterThanOrEqualTo(6));
        expect(minimal.timelinePlayheadCapHeight, greaterThanOrEqualTo(4));
      },
    );

    test('density boundary is half-open (>= breakpoint -> tier above)', () {
      expect(
        ShellResponsiveMetrics.densityForWidth(1400),
        ShellDensity.comfortable,
      );
      expect(
        ShellResponsiveMetrics.densityForWidth(1200),
        ShellDensity.compact,
      );
      expect(
        ShellResponsiveMetrics.densityForWidth(1199.99),
        ShellDensity.dense,
      );
      expect(ShellResponsiveMetrics.densityForWidth(1000), ShellDensity.dense);
      expect(ShellResponsiveMetrics.densityForWidth(999), ShellDensity.minimal);
    });

    test('height boundary is half-open, same as width', () {
      expect(
        ShellResponsiveMetrics.densityForHeight(860),
        ShellDensity.comfortable,
      );
      expect(
        ShellResponsiveMetrics.densityForHeight(859.99),
        ShellDensity.compact,
      );
      expect(ShellResponsiveMetrics.densityForHeight(740), ShellDensity.compact);
      expect(ShellResponsiveMetrics.densityForHeight(739), ShellDensity.dense);
      expect(ShellResponsiveMetrics.densityForHeight(620), ShellDensity.dense);
      expect(ShellResponsiveMetrics.densityForHeight(619), ShellDensity.minimal);
    });

    // The bug this axis exists for. A 1920x1080 display at Windows' default
    // 125% scaling hands the app 1536x816 logical pixels. Keyed off width
    // alone that read as `comfortable` — FULL-SIZE chrome, larger than the app
    // uses in its own 1280x780 default window — while 816px of height had to
    // fit toolbar, inspector, preview, timeline toolbar, ruler and lanes. The
    // clip lane landed below the bottom of the screen, with nothing to scroll
    // and no divider to drag, so cutting and trimming were unreachable.
    test('a 1080p display at 125% scaling does not get comfortable chrome', () {
      const dpiScaled1080p = Size(1536, 816);
      expect(
        ShellResponsiveMetrics.densityForWidth(dpiScaled1080p.width),
        ShellDensity.comfortable,
        reason: 'width alone still reads as comfortable — that was the trap',
      );
      final m = ShellResponsiveMetrics.fromSize(dpiScaled1080p);
      expect(m.density, ShellDensity.compact);
      expect(m.scale, 0.92);
    });

    test('density is the tighter of the two axes, never the looser', () {
      // Wide but short: height constrains.
      expect(
        ShellResponsiveMetrics.densityForSize(const Size(1600, 700)),
        ShellDensity.dense,
      );
      // Tall but narrow: width constrains, exactly as before this axis existed.
      expect(
        ShellResponsiveMetrics.densityForSize(const Size(900, 1200)),
        ShellDensity.minimal,
      );
      // Both roomy: unaffected.
      expect(
        ShellResponsiveMetrics.densityForSize(const Size(1600, 900)),
        ShellDensity.comfortable,
      );
    });

    // Height must only ever constrain. If it could promote, a tall window would
    // get bigger chrome than its width can carry and overflow sideways instead
    // — the same bug rotated 90 degrees.
    test('height never promotes a width-constrained window', () {
      for (final width in const <double>[900, 1100, 1300, 1500]) {
        final byWidth = ShellResponsiveMetrics.densityForWidth(width);
        final huge = ShellResponsiveMetrics.densityForSize(Size(width, 4000));
        expect(
          huge.index,
          greaterThanOrEqualTo(byWidth.index),
          reason: 'width $width with unlimited height must not loosen',
        );
        expect(huge, byWidth);
      }
    });

    test('the default window size resolves the same on both axes', () {
      // kDefaultDesktopWindowSize is 1280x780. The height thresholds are
      // derived from it, so if either axis disagrees the derivation drifted.
      const defaultWindow = Size(1280, 780);
      expect(
        ShellResponsiveMetrics.densityForWidth(defaultWindow.width),
        ShellDensity.compact,
      );
      expect(
        ShellResponsiveMetrics.densityForHeight(defaultWindow.height),
        ShellDensity.compact,
      );
      expect(
        ShellResponsiveMetrics.fromSize(defaultWindow).density,
        ShellDensity.compact,
      );
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
