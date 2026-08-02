import 'package:clingfy/app/home/post_processing/widgets/post_color_grade_section.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

/// The whole "a drag is one undo entry" contract hangs on one wire: the
/// slider's `onChangeEnd` reaching `PostProcessingController.commitColorGrade`.
/// Every controller-level test calls `commitColorGrade()` directly, so if that
/// callback stopped firing, undo would silently never arm and all of those
/// tests would still pass. These tests pin the wire itself.
void main() {
  // The Auto-enhance row renders a MacosSwitch, which needs a MacosTheme
  // ancestor (mirrors post_processing_sidebar_test.dart).
  setUp(() => debugPlatformKindOverride = PlatformKind.macos);
  tearDown(() => debugPlatformKindOverride = null);

  Widget host({
    required ColorGrade grade,
    required ValueChanged<double> onExposure,
    required ValueChanged<double> onTint,
    required VoidCallback onChangeEnd,
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
              width: 320,
              child: SingleChildScrollView(
                child: PostColorGradeSection(
                  colorGrade: grade,
                  onAutoEnhanceChanged: (_) {},
                  onExposureChanged: onExposure,
                  onContrastChanged: (_) {},
                  onSaturationChanged: (_) {},
                  onTemperatureChanged: (_) {},
                  onTintChanged: onTint,
                  onChangeEnd: onChangeEnd,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('releasing the exposure slider commits the gesture', (
    tester,
  ) async {
    var changes = 0;
    var commits = 0;

    await tester.pumpWidget(
      host(
        grade: const ColorGrade(),
        onExposure: (_) => changes++,
        onTint: (_) {},
        onChangeEnd: () => commits++,
      ),
    );

    final slider = find.byType(AppSlider).first;
    await tester.ensureVisible(slider);
    await tester.pump();
    await tester.drag(slider, const Offset(40, 0));
    await tester.pump();

    expect(changes, greaterThan(0), reason: 'the drag streams live ticks');
    expect(commits, 1, reason: 'the release commits exactly once');
  });

  testWidgets('the last slider row is wired to onChangeEnd too', (
    tester,
  ) async {
    // All five rows go through one private helper — this proves the helper is
    // actually applied to the final row, not just the first.
    var tintChanges = 0;
    var commits = 0;

    await tester.pumpWidget(
      host(
        grade: const ColorGrade(),
        onExposure: (_) {},
        onTint: (_) => tintChanges++,
        onChangeEnd: () => commits++,
      ),
    );

    final tintSlider = find.byType(AppSlider).last;
    await tester.ensureVisible(tintSlider);
    await tester.pump();
    await tester.drag(tintSlider, const Offset(40, 0));
    await tester.pump();

    expect(tintChanges, greaterThan(0));
    expect(commits, 1);
  });
}
