import 'package:clingfy/app/home/preview/widgets/timeline/markers_timeline_lane.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('markers lane remains a non-interactive scaffold', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: MarkersTimelineLane(
                durationMs: 60000,
                visibleStartMs: 0,
                visibleEndMs: 30000,
                visibleWidth: 420,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('markers_timeline_lane')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('markers_timeline_lane')),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
  });
}
