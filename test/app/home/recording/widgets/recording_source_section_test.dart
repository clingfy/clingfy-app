import 'package:clingfy/app/home/recording/widgets/recording_source_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';

Widget _buildSection({
  DisplayTargetMode targetMode = DisplayTargetMode.explicitId,
  List<DisplayInfo>? displays,
  bool identifySupported = true,
  bool isRecording = false,
  void Function(int? id, Map<String, String> labels)? onDisplayChanged,
  void Function(Map<String, String> labels)? onIdentifyDisplays,
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
              isRecording: isRecording,
              targetMode: targetMode,
              displays: displays ?? _defaultDisplays,
              selectedDisplayId: 2,
              appWindows: const [
                AppWindowInfo(id: 99, appName: 'Safari', title: 'Dashboard'),
              ],
              selectedAppWindowId: 99,
              areaDisplayId: null,
              areaRect: null,
              onTargetModeChanged: (_) {},
              onDisplayChanged: onDisplayChanged ?? (_, _) {},
              onRefreshDisplays: () {},
              onIdentifyDisplays: onIdentifyDisplays ?? (_) {},
              identifySupported: identifySupported,
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

const List<DisplayInfo> _defaultDisplays = [
  DisplayInfo(
    id: 1,
    name: '1. Built-in Retina Display',
    x: 0,
    y: 0,
    width: 1512,
    height: 982,
    scale: 2,
    ordinal: 1,
    osName: 'Built-in Retina Display',
    isPrimary: true,
    isAppWindowHost: true,
  ),
  DisplayInfo(
    id: 2,
    name: '2. Studio Display',
    x: 1512,
    y: 0,
    width: 2560,
    height: 1440,
    scale: 2,
    ordinal: 2,
    osName: 'Studio Display',
  ),
];

Future<void> _pumpSection(
  WidgetTester tester, {
  DisplayTargetMode targetMode = DisplayTargetMode.explicitId,
  List<DisplayInfo>? displays,
  bool identifySupported = true,
  bool isRecording = false,
  void Function(int? id, Map<String, String> labels)? onDisplayChanged,
  void Function(Map<String, String> labels)? onIdentifyDisplays,
}) async {
  await tester.pumpWidget(
    _buildSection(
      targetMode: targetMode,
      displays: displays,
      identifySupported: identifySupported,
      isRecording: isRecording,
      onDisplayChanged: onDisplayChanged,
      onIdentifyDisplays: onIdentifyDisplays,
    ),
  );
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
  // Phase 10.3 forked this surface's widget tree by platform (no-op
  // controls hidden / zoom editing disabled on Windows). These legacy
  // assertions pin the macOS branch regardless of the host OS. Windows
  // hide-coverage: windows_control_hides_test.dart covers the standalone
  // sections; sidebar-level hides are pinned by the isWindows() gates.
  setUp(() {
    debugPlatformKindOverride = PlatformKind.macos;
  });
  tearDown(() {
    debugPlatformKindOverride = null;
  });

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

  testWidgets('the Main display row is selectable', (tester) async {
    // Regression test for a dead sentinel: PopupMenuButton routes a
    // null-valued selection to onCanceled, so the old
    // PlatformMenuItem(value: null) row did nothing at all when tapped.
    final picks = <int?>[];
    await _pumpSection(tester, onDisplayChanged: (id, _) => picks.add(id));

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingSourceSection)),
    )!;

    await tester.tap(find.byKey(PlatformDropdown.fieldKey).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.mainDisplay).last);
    await tester.pumpAndSettle();

    expect(picks, [null]);
  });

  testWidgets('each display row shows its ordinal and role markers', (
    tester,
  ) async {
    await _pumpSection(tester);

    await tester.tap(find.byKey(PlatformDropdown.fieldKey).at(1));
    await tester.pumpAndSettle();

    expect(
      find.text(
        '1. Built-in Retina Display — Main · This window  (1512×982 @2.0x)',
      ),
      findsOneWidget,
    );
    expect(find.text('2. Studio Display  (2560×1440 @2.0x)'), findsWidgets);
  });

  testWidgets('choosing a display reports it with the labels map', (
    tester,
  ) async {
    int? pickedId;
    Map<String, String>? pickedLabels;
    await _pumpSection(
      tester,
      onDisplayChanged: (id, labels) {
        pickedId = id;
        pickedLabels = labels;
      },
    );

    await tester.tap(find.byKey(PlatformDropdown.fieldKey).at(1));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .text(
            '1. Built-in Retina Display — Main · This window  (1512×982 @2.0x)',
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(pickedId, 1);
    expect(pickedLabels, {
      '1': '1. Built-in Retina Display — Main · This window',
      '2': '2. Studio Display',
    });
  });

  testWidgets('the identify button is hidden with a single display', (
    tester,
  ) async {
    await _pumpSection(tester, displays: [_defaultDisplays.first]);

    expect(find.byKey(const Key('identify_displays_button')), findsNothing);
  });

  testWidgets('the identify button is hidden when native cannot flash', (
    tester,
  ) async {
    await _pumpSection(tester, identifySupported: false);

    expect(find.byKey(const Key('identify_displays_button')), findsNothing);
  });

  testWidgets('tapping identify sends every display label keyed by id', (
    tester,
  ) async {
    Map<String, String>? sent;
    await _pumpSection(tester, onIdentifyDisplays: (labels) => sent = labels);

    await tester.tap(find.byKey(const Key('identify_displays_button')));
    await tester.pumpAndSettle();

    expect(sent, {
      '1': '1. Built-in Retina Display — Main · This window',
      '2': '2. Studio Display',
    });
  });

  testWidgets('the identify button explains itself on hover', (tester) async {
    await _pumpSection(tester);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingSourceSection)),
    )!;
    expect(
      find.ancestor(
        of: find.byKey(const Key('identify_displays_button')),
        matching: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == l10n.identifyDisplaysTooltip,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('identify is disabled while recording', (tester) async {
    await _pumpSection(tester, isRecording: true);

    final button = tester.widget<AppButton>(
      find.byKey(const Key('identify_displays_button')),
    );
    expect(button.onPressed, isNull);
  });
}
