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
