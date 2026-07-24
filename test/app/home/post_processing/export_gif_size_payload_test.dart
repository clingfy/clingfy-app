import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Guards the Dart side of the GIF-size bridge contract end-to-end: driving the
/// real export dialog must send the persisted `gifSize` on the `exportVideo`
/// method-channel payload. Without this, a misspelled payload key or a dropped
/// persist branch would let native silently fall back to "large" (the 1080
/// cap) on every GIF export, and the isolated dialog/DTO/policy tests would all
/// still pass. See the adversarial-review finding that motivated it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> exportCalls;
  late SettingsController settings;
  late PlayerController player;
  late PostProcessingController post;

  setUp(() async {
    await installCommonNativeMocks();
    exportCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        case 'exportVideo':
          exportCalls.add(call);
          return '/tmp/export.gif';
        default:
          return null;
      }
    });

    final nativeBridge = NativeBridge.instance;
    settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    player = PlayerController(nativeBridge: nativeBridge);
    post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    post.attachToRecording(
      sessionId: 'rec_test_session',
      projectPath: '/tmp/original.clingfyproj',
    );
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    post.dispose();
    player.dispose();
    settings.dispose();
    await clearCommonNativeMocks();
  });

  Widget hostFor(void Function(BuildContext) onTap) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildDarkTheme(),
      home: MacosTheme(
        data: buildMacosTheme(Brightness.dark),
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => onTap(context),
                child: const Text('open-export'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> runExportAndCapture(WidgetTester tester) async {
    await tester.pumpWidget(
      hostFor((context) {
        // Fire and forget: the dialog + export complete under pumpAndSettle.
        post.exportCurrentRecording(context);
      }),
    );
    await tester.tap(find.text('open-export'));
    await tester.pumpAndSettle();

    // The export dialog is up; submit it with the persisted selection.
    expect(find.text('Export'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(
      exportCalls,
      isNotEmpty,
      reason:
          'exportCurrentRecording must invoke the native exportVideo method',
    );
    return Map<String, dynamic>.from(
      exportCalls.last.arguments! as Map<dynamic, dynamic>,
    );
  }

  testWidgets('exportVideo payload carries the persisted GIF size (small)', (
    tester,
  ) async {
    await settings.export.updateExportFormat('gif');
    await settings.export.updateGifSize('small');

    final args = await runExportAndCapture(tester);

    expect(args['format'], 'gif');
    expect(
      args['gifSize'],
      'small',
      reason:
          'A misspelled key or dropped persist branch would send no/"large" '
          'gifSize, silently pinning every GIF export to the 1080 cap.',
    );
  });

  testWidgets(
    'exportVideo payload reflects a different persisted size (medium)',
    (tester) async {
      await settings.export.updateExportFormat('gif');
      await settings.export.updateGifSize('medium');

      final args = await runExportAndCapture(tester);

      expect(args['format'], 'gif');
      expect(args['gifSize'], 'medium');
    },
  );
}
