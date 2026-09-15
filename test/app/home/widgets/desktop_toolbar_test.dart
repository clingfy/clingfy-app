import 'package:clingfy/app/home/widgets/desktop_toolbar.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildToolbar({
    ToolbarNoticePresentation? notice,
    ToolbarExportStatusPresentation? exportStatus,
    VoidCallback? onExport,
    bool isExportUnavailable = false,
    bool isExporting = false,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: DesktopToolbar(
          isRecording: false,
          isPaused: false,
          notice: notice,
          exportStatus: exportStatus,
          onExport: onExport,
          isExportUnavailable: isExportUnavailable,
          isExporting: isExporting,
        ),
      ),
    );
  }

  group('the Export button', () {
    // The spinner branch lives in the macOS row; pin it regardless of the host
    // the suite runs on.
    setUp(() => debugPlatformKindOverride = PlatformKind.macos);
    tearDown(() => debugPlatformKindOverride = null);

    const exportKey = Key('toolbar_export_button');

    testWidgets('unavailable disables it without claiming an export is '
        'running', (tester) async {
      // A transcription also makes the export unavailable, and it writes no
      // file. Feeding one flag to both the disabled state and the spinner
      // announced an export that did not exist — the user watches a progress
      // spinner for a file nothing is producing.
      await tester.pumpWidget(
        buildToolbar(onExport: () {}, isExportUnavailable: true),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DesktopToolbar)),
      )!;

      expect(
        find.byKey(exportKey),
        findsOneWidget,
        reason: 'withholding the button entirely leaves nothing to explain',
      );
      expect(tester.widget<AppButton>(find.byKey(exportKey)).onPressed, isNull);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(find.text('${l10n.export}…'), findsNothing);
      expect(find.text(l10n.export), findsOneWidget);
    });

    testWidgets('a real export is what puts the spinner on it', (tester) async {
      await tester.pumpWidget(
        buildToolbar(
          onExport: () {},
          // Both, because a running export also blocks a second one — this is
          // the state the pair is meant to describe together.
          isExportUnavailable: true,
          isExporting: true,
        ),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DesktopToolbar)),
      )!;

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.text('${l10n.export}…'), findsOneWidget);
      expect(tester.widget<AppButton>(find.byKey(exportKey)).onPressed, isNull);
    });

    testWidgets('an available export is live and quiet', (tester) async {
      var exported = 0;
      await tester.pumpWidget(buildToolbar(onExport: () => exported++));

      await tester.tap(find.byKey(exportKey));
      await tester.pump();

      expect(exported, 1);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });
  });

  testWidgets('renders toolbar row without status strip when idle', (
    tester,
  ) async {
    await tester.pumpWidget(buildToolbar());

    expect(find.byKey(const Key('desktop_toolbar_row')), findsOneWidget);
    expect(find.byKey(const Key('toolbar_status_strip')), findsNothing);
  });

  testWidgets('renders paused recording badge with frozen elapsed text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: const Scaffold(
          body: DesktopToolbar(
            isRecording: true,
            isPaused: true,
            elapsedText: '00:00:05',
          ),
        ),
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(DesktopToolbar)),
    )!;

    expect(find.text('${l10n.paused} • 00:00:05'), findsOneWidget);
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

  testWidgets('show progress action invokes callback on first tap', (
    tester,
  ) async {
    var showDetailsCalls = 0;

    await tester.pumpWidget(
      buildToolbar(
        exportStatus: ToolbarExportStatusPresentation(
          progress: 0.42,
          cancelRequested: false,
          onShowDetails: () => showDetailsCalls += 1,
        ),
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(DesktopToolbar)),
    )!;

    await tester.tap(find.text(l10n.showProgress));
    await tester.pump();

    expect(showDetailsCalls, 1);
  });

  testWidgets('show progress action remains tappable after progress updates', (
    tester,
  ) async {
    final progress = ValueNotifier(0.12);
    addTearDown(progress.dispose);
    var showDetailsCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
          body: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, _) {
              return DesktopToolbar(
                isRecording: false,
                isPaused: false,
                exportStatus: ToolbarExportStatusPresentation(
                  progress: value,
                  cancelRequested: false,
                  onShowDetails: () => showDetailsCalls += 1,
                ),
              );
            },
          ),
        ),
      ),
    );

    progress.value = 0.27;
    await tester.pump();
    progress.value = 0.49;
    await tester.pump();
    progress.value = 0.73;
    await tester.pump();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(DesktopToolbar)),
    )!;

    expect(find.textContaining('73%'), findsOneWidget);

    await tester.tap(find.text(l10n.showProgress));
    await tester.pump();

    expect(showDetailsCalls, 1);
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

  testWidgets('inspector toggle renders and fires its callback', (
    tester,
  ) async {
    var toggled = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
          body: DesktopToolbar(
            isRecording: false,
            isPaused: false,
            isInspectorVisible: false,
            onToggleInspector: () => toggled += 1,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('home_toolbar_options_toggle_button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('home_toolbar_options_toggle_button')),
    );
    await tester.pump();

    expect(toggled, 1);
  });

  testWidgets('inspector toggle occupies the leading slot ahead of countdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
          body: DesktopToolbar(
            isRecording: false,
            isPaused: false,
            countdownText: '00:00:10',
            isInspectorVisible: true,
            onToggleInspector: () {},
          ),
        ),
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(DesktopToolbar)),
    )!;
    final toggleRect = tester.getRect(
      find.byKey(const Key('home_toolbar_options_toggle_button')),
    );
    final countdownRect = tester.getRect(find.text(l10n.stopIn('00:00:10')));

    expect(toggleRect.left, lessThan(countdownRect.left));
  });
}
