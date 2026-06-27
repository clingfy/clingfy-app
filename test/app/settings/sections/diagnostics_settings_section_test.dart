import 'package:clingfy/app/settings/sections/diagnostics_settings_section.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugPlatformKindOverride = PlatformKind.macos);
  tearDown(() => debugPlatformKindOverride = null);

  const channel = MethodChannel(NativeChannel.screenRecorder);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getSaveFolder') return '/tmp/clingfy';
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<SettingsController> makeSettings() async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await settings.loadPreferences();
    return settings;
  }

  Widget app(SettingsController settings) => MaterialApp(
    theme: buildLightTheme(),
    darkTheme: buildDarkTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MacosTheme(
      data: buildMacosTheme(Theme.of(context).brightness),
      child: child!,
    ),
    home: Scaffold(body: DiagnosticsSettingsSection(controller: settings)),
  );

  testWidgets('renders the verbose logging toggle, off by default', (
    tester,
  ) async {
    final settings = await makeSettings();
    addTearDown(settings.dispose);

    await tester.pumpWidget(app(settings));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('diagnostics_verbose_logging_toggle'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<AppToggleRow>(toggle).value, isFalse);
  });

  testWidgets('toggling on updates the setting and pushes the native level', (
    tester,
  ) async {
    final settings = await makeSettings();
    addTearDown(settings.dispose);

    await tester.pumpWidget(app(settings));
    await tester.pumpAndSettle();

    final toggleFinder = find.byKey(
      const Key('diagnostics_verbose_logging_toggle'),
    );
    tester.widget<AppToggleRow>(toggleFinder).onChanged!(true);
    await tester.pumpAndSettle();

    expect(settings.workspace.verboseLogging, isTrue);
    // The row rebuilt to reflect the new state (ListenableBuilder binding).
    expect(tester.widget<AppToggleRow>(toggleFinder).value, isTrue);
    // And the level was pushed to native.
    final pushes = calls.where((c) => c.method == 'setNativeLogLevel');
    expect(pushes, isNotEmpty);
    expect((pushes.last.arguments as Map)['level'], 'debug');
  });
}
