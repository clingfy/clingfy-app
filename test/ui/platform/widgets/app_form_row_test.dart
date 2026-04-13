import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  Widget buildTestApp(Widget child, {double width = 720}) {
    return MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.light,
      builder: (context, inner) => MacosTheme(
        data: buildMacosTheme(Theme.of(context).brightness),
        child: inner!,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );
  }

  testWidgets(
    'AppFormRow keeps infoTooltip beside label before trailing action',
    (tester) async {
      const trailingKey = Key('label_trailing');

      await tester.pumpWidget(
        buildTestApp(
          const AppFormRow(
            label: 'Chroma key color',
            infoTooltip: 'Target color to remove',
            labelTrailing: Icon(Icons.refresh, key: trailingKey, size: 16),
            control: SizedBox(width: 40, height: 20),
          ),
        ),
      );

      final labelRect = tester.getRect(find.text('Chroma key color'));
      final infoRect = tester.getRect(find.byTooltip('Target color to remove'));
      final trailingRect = tester.getRect(find.byKey(trailingKey));

      expect(find.text('Chroma key color'), findsOneWidget);
      expect(find.byTooltip('Target color to remove'), findsOneWidget);
      expect(find.text('Target color to remove'), findsNothing);
      expect(infoRect.left - labelRect.right, lessThanOrEqualTo(12));
      expect((infoRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
      expect(trailingRect.left, greaterThan(infoRect.right));
      expect((trailingRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
      expect(
        tester
            .widget<AppInlineInfoTooltip>(find.byType(AppInlineInfoTooltip))
            .color,
        isNull,
      );
    },
  );

  testWidgets('AppFormRow renders labelTrailing inline in wide layout', (
    tester,
  ) async {
    const trailingKey = Key('label_trailing');
    const controlKey = Key('control');

    await tester.pumpWidget(
      buildTestApp(
        const AppFormRow(
          label: 'Input device',
          labelTrailing: Icon(Icons.refresh, key: trailingKey, size: 16),
          control: SizedBox(key: controlKey, width: 40, height: 20),
        ),
      ),
    );

    final labelRect = tester.getRect(find.text('Input device'));
    final trailingRect = tester.getRect(find.byKey(trailingKey));
    final controlRect = tester.getRect(find.byKey(controlKey));

    expect(trailingRect.left, greaterThan(labelRect.right));
    expect((trailingRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
    expect(controlRect.left, greaterThan(trailingRect.right));
  });

  testWidgets('AppFormRow renders labelTrailing inline in stacked layout', (
    tester,
  ) async {
    const trailingKey = Key('label_trailing');
    const controlKey = Key('control');

    await tester.pumpWidget(
      buildTestApp(
        const AppFormRow(
          label: 'Input device',
          labelTrailing: Icon(Icons.refresh, key: trailingKey, size: 16),
          control: SizedBox(key: controlKey, width: 40, height: 20),
        ),
        width: 220,
      ),
    );

    final labelRect = tester.getRect(find.text('Input device'));
    final trailingRect = tester.getRect(find.byKey(trailingKey));
    final controlRect = tester.getRect(find.byKey(controlKey));

    expect(trailingRect.left, greaterThan(labelRect.right));
    expect((trailingRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
    expect(controlRect.top, greaterThan(trailingRect.bottom));
  });

  testWidgets('AppFormRow ignores labelTrailing for control-only rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        const AppFormRow(
          labelTrailing: Icon(Icons.refresh, key: Key('label_trailing')),
          control: SizedBox(width: 40, height: 20),
        ),
      ),
    );

    expect(find.byKey(const Key('label_trailing')), findsNothing);
  });
}
