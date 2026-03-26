import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_switch.dart';
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
        body: Center(child: SizedBox(width: 320, child: child)),
      ),
    );
  }

  Finder findSwitchPadding() {
    return find.byWidgetPredicate(
      (widget) => widget is Padding && widget.child is PlatformSwitch,
    );
  }

  testWidgets(
    'AppToggleRow renders infoTooltip as an inline tooltip without visible helper text',
    (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const AppToggleRow(
            title: 'Show cursor',
            infoTooltip: 'Toggle cursor visibility',
            value: true,
            onChanged: null,
          ),
        ),
      );

      expect(find.text('Show cursor'), findsOneWidget);
      expect(find.byTooltip('Toggle cursor visibility'), findsOneWidget);
      expect(find.text('Toggle cursor visibility'), findsNothing);

      final switchPadding = tester.widget<Padding>(findSwitchPadding());
      expect((switchPadding.padding as EdgeInsets).top, 0);
    },
  );

  testWidgets(
    'AppToggleRow keeps helperText visible and preserves stacked switch padding',
    (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const AppToggleRow(
            title: 'Warn before closing an unexported recording',
            helperText:
                'Show a confirmation before closing the current recording if it has not been exported yet.',
            value: true,
            onChanged: null,
          ),
        ),
      );

      expect(
        find.text('Warn before closing an unexported recording'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Show a confirmation before closing the current recording if it has not been exported yet.',
        ),
        findsOneWidget,
      );

      final switchPadding = tester.widget<Padding>(findSwitchPadding());
      expect((switchPadding.padding as EdgeInsets).top, 2);
    },
  );
}
