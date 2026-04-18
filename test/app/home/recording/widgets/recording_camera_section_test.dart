import 'package:clingfy/app/home/recording/widgets/recording_camera_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

Widget _buildSection({
  bool loadingCams = false,
  bool isRecording = false,
  String? selectedCamId = 'cam-1',
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
            child: RecordingCameraSection(
              isRecording: isRecording,
              cams: const [CamSource(id: 'cam-1', name: 'Built-in Camera')],
              selectedCamId: selectedCamId,
              loadingCams: loadingCams,
              onRefreshCams: () {},
              onCamSourceChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpSection(
  WidgetTester tester, {
  bool loadingCams = false,
  bool isRecording = false,
  String? selectedCamId = 'cam-1',
}) async {
  await tester.pumpWidget(
    _buildSection(
      loadingCams: loadingCams,
      isRecording: isRecording,
      selectedCamId: selectedCamId,
    ),
  );
  await tester.pump();
  if (!loadingCams) {
    await tester.pumpAndSettle();
  }
}

Finder _macosTooltip(String message) {
  return find.byWidgetPredicate(
    (widget) => widget is MacosTooltip && widget.message == message,
  );
}

void main() {
  testWidgets('camera title is hidden and refresh moves inline', (
    tester,
  ) async {
    await _pumpSection(tester);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingCameraSection)),
    )!;
    final labelRect = tester.getRect(find.text(l10n.cameraDevice));
    final refreshRect = tester.getRect(_macosTooltip(l10n.refreshCameras));

    expect(find.text(l10n.camera), findsNothing);
    expect(_macosTooltip(l10n.refreshCameras), findsOneWidget);
    expect((refreshRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
    expect(refreshRect.left, greaterThan(labelRect.right));
  });

  testWidgets('loading cameras hides inline refresh button', (tester) async {
    await _pumpSection(tester, loadingCams: true);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(RecordingCameraSection)),
    )!;

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(l10n.cameraDevice), findsNothing);
    expect(_macosTooltip(l10n.refreshCameras), findsNothing);
  });
}
