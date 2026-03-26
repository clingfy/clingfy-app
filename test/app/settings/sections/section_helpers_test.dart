import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'SettingsCard shows an inline info tooltip instead of visible subtitle text',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Theme',
              infoTooltip: 'Choose your preferred appearance',
              child: Text('Body'),
            ),
          ),
        ),
      );

      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
      expect(find.text('Choose your preferred appearance'), findsNothing);
      expect(
        find.byTooltip('Choose your preferred appearance'),
        findsOneWidget,
      );

      final icon = tester.widget<Icon>(find.byIcon(CupertinoIcons.info_circle));
      expect(icon.semanticLabel, 'Choose your preferred appearance');
    },
  );
}
