import 'package:clingfy/app/home/recording/widgets/recording_source_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

Widget _buildSection({
  DisplayTargetMode targetMode = DisplayTargetMode.explicitId,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildDarkTheme(),
    darkTheme: buildDarkTheme(),
    themeMode: ThemeMode.dark,
    home: MacosTheme(
      data: buildMacosTheme(Brightness.dark),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 720,
            child: RecordingSourceSection(
              isRecording: false,
              targetMode: targetMode,
              displays: [
                DisplayInfo(
                  id: 1,
                  name: 'Built-in Display',
                  x: 0,
                  y: 0,
                  width: 1512,
                  height: 982,
                  scale: 2,
                ),
                DisplayInfo(
                  id: 2,
                  name: 'Studio Display',
                  x: 1512,
                  y: 0,
                  width: 2560,
                  height: 1440,
                  scale: 2,
                ),
              ],
              selectedDisplayId: 2,
              appWindows: const [
                AppWindowInfo(id: 99, appName: 'Safari', title: 'Dashboard'),
              ],
              selectedAppWindowId: 99,
              areaDisplayId: null,
              areaRect: null,
              onTargetModeChanged: (_) {},
              onDisplayChanged: (_) {},
              onRefreshDisplays: () {},
              onAppWindowChanged: (_) {},
              onRefreshAppWindows: () {},
              onPickArea: () {},
              onRevealArea: () {},
              onClearArea: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpSection(
  WidgetTester tester, {
  DisplayTargetMode targetMode = DisplayTargetMode.explicitId,
}) async {
  await tester.pumpWidget(_buildSection(targetMode: targetMode));
  await tester.pump();
  await tester.pumpAndSettle();
}

Finder _macosTooltip(String message) {
  return find.byWidgetPredicate(
    (widget) => widget is MacosTooltip && widget.message == message,
  );
}

double _dropdownFieldWidthAt(WidgetTester tester, int index) {
  return tester.getSize(find.byKey(PlatformDropdown.fieldKey).at(index)).width;
}

double _dropdownMenuRowWidth(WidgetTester tester, int index) {
  return tester
      .getSize(find.byKey(ValueKey('platform_dropdown_menu_row_$index')))
      .width;
}

void main() {
  testWidgets(
    'capture source title is hidden and display refresh moves inline',
    (tester) async {
      await _pumpSection(tester);

      final l10n = AppLocalizations.of(
        tester.element(find.byType(RecordingSourceSection)),
      )!;
      final labelRect = tester.getRect(find.text(l10n.screenToRecord));
      final refreshRect = tester.getRect(_macosTooltip(l10n.refreshDisplays));

      expect(find.text(l10n.captureSource), findsNothing);
      expect(_macosTooltip(l10n.refreshDisplays), findsOneWidget);
      expect((refreshRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
      expect(refreshRect.left, greaterThan(labelRect.right));
    },
  );

  testWidgets('window refresh moves inline to window row', (tester) async {
    await _pumpSection(tester, targetMode: DisplayTargetMode.singleAppWindow);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingSourceSection)),
    )!;
    final labelRect = tester.getRect(find.text(l10n.windowToRecord));
    final refreshRect = tester.getRect(_macosTooltip(l10n.refreshWindows));

    expect(_macosTooltip(l10n.refreshWindows), findsOneWidget);
    expect((refreshRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
    expect(refreshRect.left, greaterThan(labelRect.right));
  });

  testWidgets('area mode shows no refresh and keeps helper on record target', (
    tester,
  ) async {
    await _pumpSection(tester, targetMode: DisplayTargetMode.areaRecording);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingSourceSection)),
    )!;
    final labelRect = tester.getRect(find.text(l10n.recordTarget));
    final helperRect = tester.getRect(find.byTooltip(l10n.areaRecordingHelper));

    expect(_macosTooltip(l10n.refreshDisplays), findsNothing);
    expect(_macosTooltip(l10n.refreshWindows), findsNothing);
    expect(find.byTooltip(l10n.areaRecordingHelper), findsOneWidget);
    expect((helperRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
    expect(helperRect.left - labelRect.right, lessThanOrEqualTo(12));
  });

  testWidgets(
    'chosen screen dropdowns expand beyond the old sidebar control cap',
    (tester) async {
      await _pumpSection(tester);

      expect(find.byKey(PlatformDropdown.fieldKey), findsNWidgets(2));
      expect(
        _dropdownFieldWidthAt(tester, 0),
        greaterThan(AppSidebarTokens.controlMaxWidth),
      );
      expect(
        _dropdownFieldWidthAt(tester, 1),
        greaterThan(AppSidebarTokens.controlMaxWidth),
      );

      final screenFieldWidth = _dropdownFieldWidthAt(tester, 1);

      await tester.tap(find.byKey(PlatformDropdown.fieldKey).at(1));
      await tester.pumpAndSettle();

      expect(
        _dropdownMenuRowWidth(tester, 0),
        moreOrLessEquals(screenFieldWidth),
      );
      expect(
        _dropdownMenuRowWidth(tester, 1),
        moreOrLessEquals(screenFieldWidth),
      );
      expect(
        _dropdownMenuRowWidth(tester, 2),
        moreOrLessEquals(screenFieldWidth),
      );
    },
  );

  testWidgets(
    'single-window dropdowns expand beyond the old sidebar control cap',
    (tester) async {
      await _pumpSection(tester, targetMode: DisplayTargetMode.singleAppWindow);

      expect(find.byKey(PlatformDropdown.fieldKey), findsNWidgets(2));
      expect(
        _dropdownFieldWidthAt(tester, 0),
        greaterThan(AppSidebarTokens.controlMaxWidth),
      );
      expect(
        _dropdownFieldWidthAt(tester, 1),
        greaterThan(AppSidebarTokens.controlMaxWidth),
      );

      final windowFieldWidth = _dropdownFieldWidthAt(tester, 1);

      await tester.tap(find.byKey(PlatformDropdown.fieldKey).at(1));
      await tester.pumpAndSettle();

      expect(
        _dropdownMenuRowWidth(tester, 0),
        moreOrLessEquals(windowFieldWidth),
      );
      expect(
        _dropdownMenuRowWidth(tester, 1),
        moreOrLessEquals(windowFieldWidth),
      );
    },
  );
}
