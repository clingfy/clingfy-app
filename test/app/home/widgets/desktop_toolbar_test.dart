import 'package:clingfy/app/home/widgets/desktop_toolbar.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildToolbar({
    ToolbarNoticePresentation? notice,
    ToolbarExportStatusPresentation? exportStatus,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: DesktopToolbar(
          title: 'Clingfy',
          isRecording: false,
          notice: notice,
          exportStatus: exportStatus,
        ),
      ),
    );
  }

  testWidgets('renders toolbar row without status strip when idle', (
    tester,
  ) async {
    await tester.pumpWidget(buildToolbar());

    expect(find.byKey(const Key('desktop_toolbar_row')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_status_strip')), findsNothing);
  });

  testWidgets('renders notice only in the status strip', (tester) async {
    await tester.pumpWidget(
      buildToolbar(
        notice: const ToolbarNoticePresentation(
          message: 'Saved',
          tone: ToolbarMessageTone.success,
        ),
      ),
    );

    expect(find.byKey(const Key('toolbar_status_strip')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_notice_lane')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('desktop_toolbar_row')),
        matching: find.text('Saved'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('toolbar_notice_lane')),
        matching: find.text('Saved'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders background export only in export lane', (tester) async {
    await tester.pumpWidget(
      buildToolbar(
        exportStatus: const ToolbarExportStatusPresentation(
          progress: 0.42,
          cancelRequested: false,
        ),
      ),
    );

    expect(find.byKey(const Key('toolbar_status_strip')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_export_lane')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('desktop_toolbar_row')),
        matching: find.textContaining('42%'),
      ),
      findsNothing,
    );
  });

  testWidgets('renders notice lane before export lane when both are present', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildToolbar(
        notice: const ToolbarNoticePresentation(
          message: 'Saved',
          tone: ToolbarMessageTone.success,
        ),
        exportStatus: const ToolbarExportStatusPresentation(
          progress: 0.42,
          cancelRequested: false,
        ),
      ),
    );

    final noticeTop = tester.getTopLeft(
      find.byKey(const Key('toolbar_notice_lane')),
    );
    final exportTop = tester.getTopLeft(
      find.byKey(const Key('toolbar_export_lane')),
    );

    expect(noticeTop.dy, lessThan(exportTop.dy));
  });

  testWidgets('dark toolbar row uses the shared editor chrome', (tester) async {
    final theme = buildDarkTheme();

    await tester.pumpWidget(buildToolbar());

    final surfaceFinder = find.byKey(const Key('desktop_toolbar_surface'));
    final surface = tester.widget<Container>(surfaceFinder);
    final decoration = surface.decoration! as BoxDecoration;

    expect(
      tester.getSize(surfaceFinder).height,
      theme.appEditorChrome.toolbarHeight,
    );
    expect(decoration.color, theme.appTokens.editorChromeBackground);
    expect(
      decoration.borderRadius,
      BorderRadius.circular(theme.appEditorChrome.panelRadius),
    );
    expect(decoration.border, isNull);
  });
}
