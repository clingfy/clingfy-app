import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/home/preview/widgets/close_unexported_recording_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildHarness({required Future<bool> Function() onRun}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          MacosTheme(data: MacosThemeData.light(), child: child!),
      home: Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              await onRun();
            },
            child: const Text('Run'),
          ),
        ),
      ),
    );
  }

  testWidgets('dialog renders expected warning copy', (tester) async {
    await tester.pumpWidget(
      buildHarness(
        onRun: () => confirmCloseUnexportedRecordingIfNeeded(
          tester.element(find.text('Run')),
          warningEnabled: true,
          hasExportedCurrentRecording: false,
          disableFutureWarnings: () async {},
        ),
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(find.text('Close recording without exporting?'), findsOneWidget);
    expect(
      find.text(
        'This recording hasn’t been exported yet. If you close it now, you’ll lose access to it in the current session.',
      ),
      findsOneWidget,
    );
    expect(find.text('Do not show again'), findsOneWidget);
    expect(find.text('Close Without Exporting'), findsOneWidget);
    expect(find.text('Keep Editing'), findsOneWidget);
  });

  testWidgets('keep editing keeps warning enabled', (tester) async {
    bool? result;
    var disableCalls = 0;

    await tester.pumpWidget(
      buildHarness(
        onRun: () async {
          result = await confirmCloseUnexportedRecordingIfNeeded(
            tester.element(find.text('Run')),
            warningEnabled: true,
            hasExportedCurrentRecording: false,
            disableFutureWarnings: () async {
              disableCalls += 1;
            },
          );
          return result!;
        },
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep Editing'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(disableCalls, 0);
  });

  testWidgets('confirm without checkbox closes but keeps warning enabled', (
    tester,
  ) async {
    bool? result;
    var disableCalls = 0;

    await tester.pumpWidget(
      buildHarness(
        onRun: () async {
          result = await confirmCloseUnexportedRecordingIfNeeded(
            tester.element(find.text('Run')),
            warningEnabled: true,
            hasExportedCurrentRecording: false,
            disableFutureWarnings: () async {
              disableCalls += 1;
            },
          );
          return result!;
        },
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close Without Exporting'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(disableCalls, 0);
  });

  testWidgets('confirm with checkbox closes and disables future warnings', (
    tester,
  ) async {
    bool? result;
    var disableCalls = 0;

    await tester.pumpWidget(
      buildHarness(
        onRun: () async {
          result = await confirmCloseUnexportedRecordingIfNeeded(
            tester.element(find.text('Run')),
            warningEnabled: true,
            hasExportedCurrentRecording: false,
            disableFutureWarnings: () async {
              disableCalls += 1;
            },
          );
          return result!;
        },
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Do not show again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close Without Exporting'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(disableCalls, 1);
  });

  testWidgets('helper bypasses dialog when warning already disabled', (
    tester,
  ) async {
    bool? result;
    var disableCalls = 0;

    await tester.pumpWidget(
      buildHarness(
        onRun: () async {
          result = await confirmCloseUnexportedRecordingIfNeeded(
            tester.element(find.text('Run')),
            warningEnabled: false,
            hasExportedCurrentRecording: false,
            disableFutureWarnings: () async {
              disableCalls += 1;
            },
          );
          return result!;
        },
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(disableCalls, 0);
    expect(find.text('Close recording without exporting?'), findsNothing);
  });

  testWidgets(
    'helper bypasses dialog when current recording was already exported',
    (tester) async {
      bool? result;
      var disableCalls = 0;

      await tester.pumpWidget(
        buildHarness(
          onRun: () async {
            result = await confirmCloseUnexportedRecordingIfNeeded(
              tester.element(find.text('Run')),
              warningEnabled: true,
              hasExportedCurrentRecording: true,
              disableFutureWarnings: () async {
                disableCalls += 1;
              },
            );
            return result!;
          },
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(disableCalls, 0);
      expect(find.text('Close recording without exporting?'), findsNothing);
    },
  );
}
