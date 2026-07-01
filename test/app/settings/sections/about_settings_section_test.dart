import 'package:clingfy/app/settings/sections/about_settings_section.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Phase 10.6 — the About section's Check for Updates flow.
///
/// Windows: the button is BACK (10.3 hid it while checkForUpdates was a
/// hardcoded-false stub) and drives an honest inline status from the
/// updater event channel, plus the update-available dialog. macOS: button
/// unchanged, Sparkle owns all the UI, no inline status ever renders.
void main() {
  final captured = <MethodCall>[];

  setUp(() async {
    await installCommonNativeMocks();
    captured.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenRecorderChannel, (call) async {
          captured.add(call);
          if (call.method == 'checkForUpdates') {
            return true;
          }
          return null;
        });
    NativeBridge.instance.isUpdateAvailable.value = false;
  });

  tearDown(() async {
    debugPlatformKindOverride = null;
    await clearCommonNativeMocks();
  });

  Future<void> emitUpdaterEvent(Map<String, dynamic> event) async {
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          NativeChannel.updaterEvents,
          codec.encodeSuccessEnvelope(event),
          (_) {},
        );
  }

  Widget host() {
    return MaterialApp(
      localizationsDelegates: const [
        ...AppLocalizations.localizationsDelegates,
        fluent.FluentLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, c) => fluent.FluentTheme(
        data: fluent.FluentThemeData(),
        child: MacosTheme(data: MacosThemeData.light(), child: c!),
      ),
      // buildSectionPage already returns a ListView — no extra scroll view
      // (nesting one gives the viewport unbounded height).
      home: const Scaffold(body: AboutSettingsSection()),
    );
  }

  group('Windows', () {
    testWidgets('button is visible and starts a check', (tester) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      final button = find.text('Check for Updates');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pump();

      expect(captured.any((c) => c.method == 'checkForUpdates'), isTrue);
      expect(find.text('Checking for updates…'), findsOneWidget);
    });

    testWidgets('noUpdateAvailable renders the up-to-date line', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await emitUpdaterEvent(const {
        'type': 'noUpdateAvailable',
        'version': '1.0.4',
      });
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('about_update_up_to_date')), findsOneWidget);
    });

    testWidgets('updateError renders the failure line', (tester) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await emitUpdaterEvent(const {
        'type': 'updateError',
        'code': 'UPDATE_FEED_UNREACHABLE',
        'message': 'feed returned HTTP 503',
      });
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('about_update_check_failed')),
        findsOneWidget,
      );
    });

    testWidgets(
      'updateAvailable after a user-started check shows the dialog and the '
      'inline download UI',
      (tester) async {
        debugPlatformKindOverride = PlatformKind.windows;
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Check for Updates'));
        await tester.pump();

        await emitUpdaterEvent(const {
          'type': 'updateAvailable',
          'version': '1.0.5',
          'build': '7',
          'url': 'https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe',
          'versionFull': '1.0.5+7',
        });
        await tester.pumpAndSettle();

        // Dialog with the advertised version and both actions.
        expect(find.text('Update available'), findsOneWidget);
        expect(
          find.text('Clingfy 1.0.5+7 is available for download.'),
          findsWidgets,
        );
        expect(find.text('Later'), findsOneWidget);

        await tester.tap(find.text('Later'));
        await tester.pumpAndSettle();
        expect(find.text('Update available'), findsNothing);

        // Inline status keeps the download affordance after dismissal.
        expect(find.byKey(const Key('about_update_available')), findsOneWidget);
        expect(find.text('Download update'), findsOneWidget);
      },
    );

    testWidgets('an unsolicited updateAvailable does not pop the dialog', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await emitUpdaterEvent(const {
        'type': 'updateAvailable',
        'version': '1.0.5',
        'url': 'https://dl.example/x.exe',
      });
      await tester.pumpAndSettle();

      // Inline UI yes, modal no — the user did not start this check.
      expect(find.byKey(const Key('about_update_available')), findsOneWidget);
      expect(find.text('Update available'), findsNothing);
    });
  });

  group('macOS', () {
    testWidgets('button visible, Sparkle owns the UI, no inline status', (
      tester,
    ) async {
      debugPlatformKindOverride = PlatformKind.macos;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      final button = find.text('Check for Updates');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pump();
      expect(captured.any((c) => c.method == 'checkForUpdates'), isTrue);

      // Updater events never render inline on macOS (no subscription).
      await emitUpdaterEvent(const {
        'type': 'noUpdateAvailable',
        'version': '1.0.4',
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('about_update_up_to_date')), findsNothing);
    });
  });
}
