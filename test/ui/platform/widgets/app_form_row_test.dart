import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
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
    'AppFormRow renders infoTooltip inline without visible helper text',
    (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const AppFormRow(
            label: 'Chroma key color',
            infoTooltip: 'Target color to remove',
            control: SizedBox(width: 40, height: 20),
          ),
        ),
      );

      expect(find.text('Chroma key color'), findsOneWidget);
      expect(find.byTooltip('Target color to remove'), findsOneWidget);
      expect(find.text('Target color to remove'), findsNothing);
      expect(
        tester
            .widget<AppInlineInfoTooltip>(find.byType(AppInlineInfoTooltip))
            .color,
        isNull,
      );
    },
  );
}
