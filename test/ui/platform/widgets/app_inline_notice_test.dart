import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 320, child: child)),
    ),
  );
}

void main() {
  group('AppInlineNotice details', () {
    testWidgets('without details the message wraps freely', (tester) async {
      await tester.pumpWidget(
        _host(
          const AppInlineNotice(
            message: 'A long explanation that is allowed to wrap over lines.',
            variant: AppInlineNoticeVariant.warning,
          ),
        ),
      );

      final text = tester.widget<Text>(find.byType(Text));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNull);
      expect(find.byType(Tooltip), findsNothing);
      expect(find.byIcon(Icons.info_outline), findsNothing);
    });

    testWidgets('with details the message is held to one line', (tester) async {
      await tester.pumpWidget(
        _host(
          const AppInlineNotice(
            message: 'Mic level too low',
            details: 'Raise the input level in System Settings.',
            variant: AppInlineNoticeVariant.warning,
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Mic level too low'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('details become the tooltip, and hint the hover', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const AppInlineNotice(
            message: 'Mic level too low',
            details: 'Raise the input level in System Settings.',
            variant: AppInlineNoticeVariant.warning,
          ),
        ),
      );

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Raise the input level in System Settings.');
      // Without a visible affordance nobody knows there is more to read.
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });

    testWidgets('the headline stays readable without hovering', (tester) async {
      // The whole point of the compact form: the CONDITION is visible on
      // sight, and only the detail costs a hover. A version that hid the
      // headline too would reinstate the bug this component was promoted for.
      await tester.pumpWidget(
        _host(
          const AppInlineNotice(
            message: 'Mic level too low',
            details: 'Raise the input level in System Settings.',
            variant: AppInlineNoticeVariant.warning,
          ),
        ),
      );

      expect(find.text('Mic level too low'), findsOneWidget);
      final rect = tester.getRect(find.text('Mic level too low'));
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
    });
  });
}
