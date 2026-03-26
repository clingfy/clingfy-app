import 'package:clingfy/ui/platform/widgets/app_section.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  Widget buildTestApp(Widget child) {
    return MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.light,
      builder: (context, inner) => MacosTheme(
        data: buildMacosTheme(Theme.of(context).brightness),
        child: inner!,
      ),
      home: Scaffold(
        body: Center(child: SizedBox(width: 720, child: child)),
      ),
    );
  }

  testWidgets(
    'AppSection renders infoTooltip inline without visible helper text',
    (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const AppSection(
            title: 'Area Recording',
            infoTooltip: 'Record a custom rectangular area of the screen.',
            child: Text('Body'),
          ),
        ),
      );

      expect(find.text('AREA RECORDING'), findsOneWidget);
      expect(
        find.byTooltip('Record a custom rectangular area of the screen.'),
        findsOneWidget,
      );
      expect(
        find.text('Record a custom rectangular area of the screen.'),
        findsNothing,
      );
    },
  );
}
