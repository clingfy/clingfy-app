import 'package:clingfy/ui/platform/widgets/app_sidebar_rail_button.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(ShellResponsiveMetrics metrics, Widget child) {
  return MaterialApp(
    home: ResponsiveShellScope(
      metrics: metrics,
      child: Material(child: Center(child: child)),
    ),
  );
}

double _iconButtonIconSize(WidgetTester tester) {
  return tester.widget<IconButton>(find.byType(IconButton)).iconSize!;
}

double _iconButtonConstraintWidth(WidgetTester tester) {
  return tester
      .widget<IconButton>(find.byType(IconButton))
      .constraints!
      .maxWidth;
}

void main() {
  testWidgets('AppSidebarRailButton uses metrics defaults when sizes omitted',
      (tester) async {
    final comfortable = ShellResponsiveMetrics.fromSize(const Size(1500, 900));
    await tester.pumpWidget(
      _wrap(
        comfortable,
        AppSidebarRailButton(
          icon: Icons.menu,
          tooltip: 'menu',
          onTap: () {},
        ),
      ),
    );
    expect(_iconButtonIconSize(tester), comfortable.railIconSize);
    expect(_iconButtonConstraintWidth(tester), comfortable.railButtonSize);
  });

  testWidgets('AppSidebarRailButton shrinks at minimal density', (tester) async {
    final minimal = ShellResponsiveMetrics.fromSize(const Size(820, 760));
    await tester.pumpWidget(
      _wrap(
        minimal,
        AppSidebarRailButton(
          icon: Icons.menu,
          tooltip: 'menu',
          onTap: () {},
        ),
      ),
    );
    expect(_iconButtonIconSize(tester), minimal.railIconSize);
    expect(_iconButtonConstraintWidth(tester), minimal.railButtonSize);
    expect(minimal.railButtonSize, lessThan(40));
    expect(minimal.railButtonSize, greaterThanOrEqualTo(34));
    expect(minimal.railIconSize, lessThan(28));
    expect(minimal.railIconSize, greaterThanOrEqualTo(20));
  });

  testWidgets('AppSidebarRailButton explicit sizes override metrics',
      (tester) async {
    final minimal = ShellResponsiveMetrics.fromSize(const Size(820, 760));
    await tester.pumpWidget(
      _wrap(
        minimal,
        AppSidebarRailButton(
          icon: Icons.menu,
          tooltip: 'menu',
          onTap: () {},
          buttonSize: 50,
          iconSize: 30,
        ),
      ),
    );
    expect(_iconButtonIconSize(tester), 30);
    expect(_iconButtonConstraintWidth(tester), 50);
  });

  testWidgets('AppSidebarRailButton without scope uses legacy defaults',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Center(
            child: AppSidebarRailButton(
              icon: Icons.menu,
              tooltip: 'menu',
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    expect(_iconButtonIconSize(tester), 28);
    expect(_iconButtonConstraintWidth(tester), 40);
  });
}
