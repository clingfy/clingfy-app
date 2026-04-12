import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'renders title, description, info tooltip, trailing, and children',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSettingsGroup(
              title: 'Capture Source',
              description: 'Choose what to record.',
              infoTooltip: 'Helpful context',
              trailing: IconButton(
                onPressed: () {},
                icon: const Icon(Icons.refresh),
              ),
              children: const [Text('Record target row')],
            ),
          ),
        ),
      );

      expect(find.text('Capture Source'), findsOneWidget);
      expect(find.text('Choose what to record.'), findsOneWidget);
      expect(find.text('Record target row'), findsOneWidget);
      expect(find.byTooltip('Helpful context'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(
        tester
            .widget<AppInlineInfoTooltip>(find.byType(AppInlineInfoTooltip))
            .color,
        isNull,
      );
    },
  );
}
