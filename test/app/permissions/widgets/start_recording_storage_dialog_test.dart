import 'package:clingfy/app/permissions/widgets/start_recording_storage_dialog.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDialog(
    WidgetTester tester, {
    required RecordingStoragePreflight storage,
    bool? showLowStorageBypass,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            MacosTheme(data: MacosThemeData.light(), child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                StartRecordingStorageDialog.show(
                  context,
                  storage: storage,
                  showLowStorageBypass: showLowStorageBypass,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('warning dialog shows record anyway and storage settings', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      storage: const RecordingStoragePreflight(
        status: RecordingStoragePreflightStatus.warning,
        availableBytes: 15 * 1024 * 1024 * 1024,
        warningThresholdBytes: 20 * 1024 * 1024 * 1024,
        criticalThresholdBytes: 10 * 1024 * 1024 * 1024,
      ),
    );

    expect(find.text('Record anyway'), findsOneWidget);
    expect(find.text('Open Storage Settings'), findsOneWidget);
    expect(find.byKey(const Key('storage_dialog_close')), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('critical dialog shows open storage settings and cancel only', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      storage: const RecordingStoragePreflight(
        status: RecordingStoragePreflightStatus.critical,
        availableBytes: 5 * 1024 * 1024 * 1024,
        warningThresholdBytes: 20 * 1024 * 1024 * 1024,
        criticalThresholdBytes: 10 * 1024 * 1024 * 1024,
      ),
      showLowStorageBypass: false,
    );

    expect(find.text('Open Storage Settings'), findsOneWidget);
    expect(find.byKey(const Key('storage_dialog_close')), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Record anyway'), findsNothing);
    expect(find.text('Bypass and record'), findsNothing);
  });

  testWidgets('critical dialog shows bypass action in dev mode', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      storage: const RecordingStoragePreflight(
        status: RecordingStoragePreflightStatus.critical,
        availableBytes: 5 * 1024 * 1024 * 1024,
        warningThresholdBytes: 20 * 1024 * 1024 * 1024,
        criticalThresholdBytes: 10 * 1024 * 1024 * 1024,
      ),
      showLowStorageBypass: true,
    );

    expect(find.text('Open Storage Settings'), findsOneWidget);
    expect(find.byKey(const Key('storage_dialog_close')), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Bypass and record'), findsOneWidget);
  });
}
