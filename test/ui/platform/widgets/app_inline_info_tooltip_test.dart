import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildTestApp(ThemeMode themeMode) {
    return MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      home: const Scaffold(
        body: AppInlineInfoTooltip(message: 'Helpful context'),
      ),
    );
  }

  testWidgets('uses a neutral helper icon color in light mode', (tester) async {
    await tester.pumpWidget(buildTestApp(ThemeMode.light));

    final icon = tester.widget<Icon>(find.byIcon(CupertinoIcons.info_circle));

    expect(icon.color, const Color(0xFF6E6E73));
    expect(icon.semanticLabel, 'Helpful context');
  });

  testWidgets('uses a neutral helper icon color in dark mode', (tester) async {
    await tester.pumpWidget(buildTestApp(ThemeMode.dark));

    final icon = tester.widget<Icon>(find.byIcon(CupertinoIcons.info_circle));

    expect(icon.color, const Color(0xFF8E8E93));
    expect(icon.semanticLabel, 'Helpful context');
  });
}
