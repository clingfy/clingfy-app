import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart' as app;
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  testWidgets(
    'selected labels stay constrained to the field width without overflow',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: ThemeMode.dark,
          builder: (context, child) => fluent.FluentTheme(
            data: buildFluentTheme(Brightness.dark),
            child: MacosTheme(
              data: buildMacosTheme(Brightness.dark),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                child: app.PlatformDropdown<String>(
                  value: 'project',
                  onChanged: (_) {},
                  items: const [
                    app.PlatformMenuItem(
                      value: 'project',
                      label:
                          'Very long project title that should not resize the popup button',
                    ),
                    app.PlatformMenuItem(
                      value: 'second',
                      label:
                          'Another wide option label to verify constrained selection rendering',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(app.PlatformDropdown<String>), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
