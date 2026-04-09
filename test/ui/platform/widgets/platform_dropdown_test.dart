import 'dart:ui';

import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart' as app;
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildDropdownApp({
    required ThemeMode themeMode,
    String? value = 'project',
    ValueChanged<String?>? onChanged,
    double width = 220,
    double maxWidth = 360,
    List<app.PlatformMenuItem<String>>? items,
  }) {
    return MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: app.PlatformDropdown<String>(
              value: value,
              onChanged: onChanged ?? (_) {},
              maxWidth: maxWidth,
              expand: false,
              items:
                  items ??
                  const [
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
    );
  }

  AnimatedContainer dropdownField(WidgetTester tester) {
    return tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(app.PlatformDropdown<String>),
        matching: find.byKey(app.PlatformDropdown.fieldKey),
      ),
    );
  }

  Text dropdownLabel(WidgetTester tester) {
    return tester.widget<Text>(
      find.descendant(
        of: find.byType(app.PlatformDropdown<String>),
        matching: find.byKey(app.PlatformDropdown.labelKey),
      ),
    );
  }

  Icon dropdownArrow(WidgetTester tester) {
    return tester.widget<Icon>(
      find.descendant(
        of: find.byType(app.PlatformDropdown<String>),
        matching: find.byKey(app.PlatformDropdown.arrowKey),
      ),
    );
  }

  BoxDecoration fieldDecoration(WidgetTester tester) {
    return dropdownField(tester).decoration! as BoxDecoration;
  }

  BoxDecoration menuRowDecoration(WidgetTester tester, int index) {
    return tester
            .widget<AnimatedContainer>(
              find.byKey(ValueKey('platform_dropdown_menu_row_$index')),
            )
            .decoration!
        as BoxDecoration;
  }

  double dropdownFieldWidth(WidgetTester tester) {
    return tester.getSize(find.byKey(app.PlatformDropdown.fieldKey)).width;
  }

  double dropdownMenuRowWidth(WidgetTester tester, int index) {
    return tester
        .getSize(find.byKey(ValueKey('platform_dropdown_menu_row_$index')))
        .width;
  }

  Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer();
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets(
    'selected labels stay constrained to the field width without overflow',
    (tester) async {
      await tester.pumpWidget(buildDropdownApp(themeMode: ThemeMode.dark));
      await tester.pumpAndSettle();

      expect(find.byType(app.PlatformDropdown<String>), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dark theme uses custom field colors and normal arrow', (
    tester,
  ) async {
    await tester.pumpWidget(buildDropdownApp(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    final decoration = fieldDecoration(tester);
    final label = dropdownLabel(tester);
    final arrow = dropdownArrow(tester);

    expect(decoration.color, const Color(0xFF232428));
    expect(label.style?.color, const Color(0xFF797A7E));
    expect(arrow.icon, Icons.keyboard_arrow_down);
    expect(arrow.color, const Color(0xFF797A7E));
  });

  testWidgets('light theme uses custom field colors and text color', (
    tester,
  ) async {
    await tester.pumpWidget(buildDropdownApp(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    final decoration = fieldDecoration(tester);
    final label = dropdownLabel(tester);
    final arrow = dropdownArrow(tester);

    expect(decoration.color, const Color(0xFFF3F4F7));
    expect(label.style?.color, const Color(0xFF5F636B));
    expect(arrow.color, const Color(0xFF5F636B));
  });

  testWidgets('opened menu matches the closed field width', (tester) async {
    await tester.pumpWidget(
      buildDropdownApp(
        themeMode: ThemeMode.dark,
        width: 220,
        items: const [
          app.PlatformMenuItem(value: 'short', label: 'Short'),
          app.PlatformMenuItem(
            value: 'long',
            label:
                'This is a much longer menu item label that should expand the opened menu width',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final resolvedFieldWidth = dropdownFieldWidth(tester);

    await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();

    final resolvedMenuRowWidth = dropdownMenuRowWidth(tester, 0);

    expect(resolvedMenuRowWidth, moreOrLessEquals(resolvedFieldWidth));
  });

  testWidgets('opened menu matches a fixed narrow field width', (tester) async {
    await tester.pumpWidget(
      buildDropdownApp(themeMode: ThemeMode.dark, width: 100),
    );
    await tester.pumpAndSettle();

    expect(dropdownFieldWidth(tester), moreOrLessEquals(100));

    await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();

    expect(dropdownMenuRowWidth(tester, 0), moreOrLessEquals(100));
  });

  testWidgets(
    'opened menu matches the full rendered field width when max width is unbounded',
    (tester) async {
      await tester.pumpWidget(
        buildDropdownApp(
          themeMode: ThemeMode.dark,
          width: 420,
          maxWidth: double.infinity,
        ),
      );
      await tester.pumpAndSettle();

      expect(dropdownFieldWidth(tester), moreOrLessEquals(420));

      await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
      await tester.pumpAndSettle();

      expect(dropdownMenuRowWidth(tester, 0), moreOrLessEquals(420));
    },
  );

  testWidgets('field and menu width respect the shared max-width cap', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildDropdownApp(
        themeMode: ThemeMode.dark,
        width: 420,
        items: const [
          app.PlatformMenuItem(value: 'short', label: 'Short'),
          app.PlatformMenuItem(
            value: 'huge',
            label:
                'This label is intentionally extremely long so the dropdown tries to expand far beyond the viewport safe width cap and should still be constrained cleanly without blowing out the popup layout in the widget test environment',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(dropdownFieldWidth(tester), moreOrLessEquals(360));

    await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();

    final resolvedMenuRowWidth = dropdownMenuRowWidth(tester, 0);

    expect(resolvedMenuRowWidth, moreOrLessEquals(360));
  });

  testWidgets(
    'long menu labels stay single-line and ellipsized within field width',
    (tester) async {
      const longLabel =
          'This label is intentionally extremely long so it should stay on one line and ellipsize inside the dropdown menu row instead of widening the popup';

      await tester.pumpWidget(
        buildDropdownApp(
          themeMode: ThemeMode.dark,
          width: 220,
          items: const [
            app.PlatformMenuItem(value: 'short', label: 'Short'),
            app.PlatformMenuItem(value: 'huge', label: longLabel),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
      await tester.pumpAndSettle();

      final menuText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('platform_dropdown_menu_row_1')),
          matching: find.text(longLabel),
        ),
      );

      expect(menuText.maxLines, 1);
      expect(menuText.overflow, TextOverflow.ellipsis);
      expect(
        dropdownMenuRowWidth(tester, 1),
        moreOrLessEquals(dropdownFieldWidth(tester)),
      );
    },
  );

  testWidgets('closed field hover changes decoration', (tester) async {
    await tester.pumpWidget(buildDropdownApp(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    final before = fieldDecoration(tester);

    final gesture = await hover(
      tester,
      find.byKey(app.PlatformDropdown.fieldKey),
    );
    final after = fieldDecoration(tester);

    expect(after.color, isNot(before.color));
    expect(
      (after.border! as Border).top.color,
      isNot((before.border! as Border).top.color),
    );

    await gesture.removePointer();
  });

  testWidgets('open field state changes decoration', (tester) async {
    await tester.pumpWidget(buildDropdownApp(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    final before = fieldDecoration(tester);

    await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();

    final after = fieldDecoration(tester);
    final arrow = dropdownArrow(tester);

    expect(after.color, isNot(before.color));
    expect(
      (after.border! as Border).top.color,
      isNot((before.border! as Border).top.color),
    );
    expect(arrow.color, isNot(const Color(0xFF797A7E)));
  });

  testWidgets('selected row styling differs from unselected rows', (
    tester,
  ) async {
    await tester.pumpWidget(buildDropdownApp(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();

    final selected = menuRowDecoration(tester, 0);
    final unselected = menuRowDecoration(tester, 1);

    expect(selected.color, isNot(unselected.color));
  });

  testWidgets('hover styling appears on menu rows', (tester) async {
    await tester.pumpWidget(buildDropdownApp(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();

    final before = menuRowDecoration(tester, 1);
    final gesture = await hover(
      tester,
      find.byKey(const ValueKey('platform_dropdown_menu_row_1')),
    );
    final after = menuRowDecoration(tester, 1);

    expect(after.color, isNot(before.color));

    await gesture.removePointer();
  });

  testWidgets('tapping opens menu and selecting item calls onChanged', (
    tester,
  ) async {
    String? changedValue;

    await tester.pumpWidget(
      buildDropdownApp(
        themeMode: ThemeMode.dark,
        onChanged: (value) {
          changedValue = value;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(app.PlatformDropdown.fieldKey));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Another wide option label to verify constrained selection rendering',
      ),
      findsOneWidget,
    );

    await tester.tap(
      find
          .text(
            'Another wide option label to verify constrained selection rendering',
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(changedValue, 'second');
  });
}
