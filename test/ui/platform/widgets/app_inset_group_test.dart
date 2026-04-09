import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders children inside a structure-only inset wrapper', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppInsetGroup(
            children: [
              Text('Nested setting'),
              SizedBox(height: AppSidebarTokens.rowGap),
              Text('Advanced control'),
            ],
          ),
        ),
      ),
    );

    final padding = tester.widget<Padding>(
      find.descendant(
        of: find.byType(AppInsetGroup),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Padding &&
              widget.padding ==
                  const EdgeInsets.all(AppSidebarTokens.insetPadding),
        ),
      ),
    );

    expect(find.text('Nested setting'), findsOneWidget);
    expect(find.text('Advanced control'), findsOneWidget);
    expect(
      padding.padding,
      const EdgeInsets.all(AppSidebarTokens.insetPadding),
    );
    expect(
      find.descendant(
        of: find.byType(AppInsetGroup),
        matching: find.byWidgetPredicate(
          (widget) => widget is Container && widget.decoration != null,
        ),
      ),
      findsNothing,
    );
  });
}
