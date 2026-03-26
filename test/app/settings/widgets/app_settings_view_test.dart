import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/shortcuts/shortcut_config.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/widgets/about_view.dart';
import 'package:clingfy/app/settings/widgets/app_settings_view.dart';
import 'package:clingfy/app/settings/sections/keyboard_shortcuts_settings.dart';
import 'package:clingfy/app/settings/sections/about_settings_section.dart';
import 'package:clingfy/app/settings/sections/diagnostics_settings_section.dart';
import 'package:clingfy/app/settings/sections/storage_settings_section.dart';
import 'package:clingfy/commercial/licensing/settings/license_settings_section.dart';
import 'package:clingfy/app/settings/sections/permissions_settings_section.dart';
import 'package:clingfy/app/settings/sections/workspace_settings_section.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );
  const screenRecorderChannel = MethodChannel(NativeChannel.screenRecorder);

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, (call) async {
          if (call.method == 'getAll') {
            return <String, dynamic>{
              'appName': 'Clingfy',
              'packageName': 'com.clingfy.app',
              'version': '1.2.0',
              'buildNumber': '120',
              'buildSignature': '',
            };
          }
          return null;
        });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenRecorderChannel, null);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenRecorderChannel, (call) async {
          switch (call.method) {
            case 'getPermissionStatus':
              return <String, bool>{
                'screenRecording': false,
                'microphone': false,
                'camera': false,
                'accessibility': false,
              };
            case 'getStorageSnapshot':
              return <String, dynamic>{
                'systemTotalBytes': 500 * 1024 * 1024 * 1024,
                'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
                'recordingsBytes': 4 * 1024 * 1024,
                'tempBytes': 2 * 1024 * 1024,
                'logsBytes': 512 * 1024,
                'recordingsPath': '/tmp/Clingfy/Recordings',
                'tempPath': '/tmp/Clingfy/Temp',
                'logsPath': '/tmp/Clingfy/Logs',
                'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
                'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
              };
            default:
              return null;
          }
        });
  });

  Widget buildTestApp({
    required SettingsController settings,
    SettingsSection initialSection = SettingsSection.workspace,
    ThemeMode themeMode = ThemeMode.light,
  }) {
    return ChangeNotifierProvider<LicenseController>(
      create: (_) => LicenseController(),
      child: MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: themeMode,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MacosTheme(
          data: buildMacosTheme(Theme.of(context).brightness),
          child: child!,
        ),
        home: AppSettingsView(
          controller: settings,
          initialSection: initialSection,
        ),
      ),
    );
  }

  Finder findMacosTooltip(String message) {
    return find.byWidgetPredicate(
      (widget) => widget is MacosTooltip && widget.message == message,
    );
  }

  testWidgets('settings rail renders seven sections', (tester) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);

    await tester.pumpWidget(buildTestApp(settings: settings));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    // expect(find.text('App Settings'), findsOneWidget);
    expect(
      find.text('Theme, language, and save-folder behavior.'),
      findsOneWidget,
    );
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Storage'), findsWidgets);
    expect(find.text('Keyboard Shortcuts'), findsWidgets);
    expect(find.text('License'), findsWidgets);
    expect(find.text('Permissions'), findsWidgets);
    expect(find.text('Diagnostics'), findsWidgets);
    expect(find.text('About'), findsWidgets);
  });

  testWidgets('inline close action pops settings route', (tester) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);

    await tester.pumpWidget(
      ChangeNotifierProvider<LicenseController>(
        create: (_) => LicenseController(),
        child: MaterialApp(
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: ThemeMode.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MacosTheme(
            data: buildMacosTheme(Theme.of(context).brightness),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AppSettingsView(controller: settings),
                      ),
                    );
                  },
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsView), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(AppSettingsView), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('tapping sections swaps content', (tester) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await tester.pumpWidget(buildTestApp(settings: settings));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceSettingsSection), findsOneWidget);
    expect(
      find.text('Theme, language, and save-folder behavior.'),
      findsOneWidget,
    );
    await tester.drag(
      find.descendant(
        of: find.byType(WorkspaceSettingsSection),
        matching: find.byType(ListView),
      ),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(find.text('Confirmations'), findsOneWidget);
    expect(find.text('Show Action Bar'), findsOneWidget);
    expect(
      find.text('Warn before closing an unexported recording'),
      findsOneWidget,
    );

    await tester.tap(find.text('Storage'));
    await tester.pumpAndSettle();
    expect(find.byType(StorageSettingsSection), findsOneWidget);
    expect(
      find.text('Recording space, internal usage, and disk health.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Keyboard Shortcuts'));
    await tester.pumpAndSettle();
    expect(find.byType(KeyboardShortcutsSettings), findsOneWidget);
    expect(find.text('Keyboard Shortcuts'), findsNWidgets(2));
    expect(
      find.text('Customize keyboard shortcuts and resolve conflicts.'),
      findsOneWidget,
    );

    await tester.tap(find.text('License'));
    await tester.pumpAndSettle();
    expect(find.byType(LicenseSettingsSection), findsOneWidget);
    expect(
      find.text('Plan status, entitlement, device link, and upgrade actions.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Permissions'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsSettingsSection), findsOneWidget);
    expect(
      find.text('Access status and quick links to System Settings.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.byType(DiagnosticsSettingsSection), findsOneWidget);

    await tester.ensureVisible(find.text('About'));
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutSettingsSection), findsOneWidget);
  });

  testWidgets('settings cards expose help text as inline macOS tooltips', (
    tester,
  ) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);

    await tester.pumpWidget(buildTestApp(settings: settings));
    await tester.pumpAndSettle();

    expect(
      findMacosTooltip('Choose your preferred appearance'),
      findsOneWidget,
    );
    expect(find.text('Choose your preferred appearance'), findsNothing);

    await tester.drag(
      find.descendant(
        of: find.byType(WorkspaceSettingsSection),
        matching: find.byType(ListView),
      ),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(
      findMacosTooltip(
        'Show a confirmation before closing the current recording if it has not been exported yet.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Show a confirmation before closing the current recording if it has not been exported yet.',
      ),
      findsNothing,
    );

    await tester.tap(find.text('Storage'));
    await tester.pumpAndSettle();
    expect(
      findMacosTooltip(
        'Monitor system free space and Clingfy workspace usage to avoid failed recordings.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Monitor system free space and Clingfy workspace usage to avoid failed recordings.',
      ),
      findsNothing,
    );

    await tester.tap(find.text('License'));
    await tester.pumpAndSettle();
    expect(
      findMacosTooltip('Your current plan, entitlement, and update coverage.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Permissions'));
    await tester.pumpAndSettle();
    expect(
      findMacosTooltip(
        'Review which permissions Clingfy can use and jump directly to the relevant System Settings pane.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(
      findMacosTooltip(
        'If something goes wrong, open the logs folder and send today\'s log file to support.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('/about route opens settings on About section', (tester) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);

    await tester.pumpWidget(
      ChangeNotifierProvider<LicenseController>(
        create: (_) => LicenseController(),
        child: MaterialApp(
          initialRoute: AboutView.routeName,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: ThemeMode.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MacosTheme(
            data: buildMacosTheme(Theme.of(context).brightness),
            child: child!,
          ),
          routes: {
            AppSettingsView.routeName: (_) =>
                AppSettingsView(controller: settings),
            AboutView.routeName: (_) => AppSettingsView(
              controller: settings,
              initialSection: SettingsSection.about,
            ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AboutSettingsSection), findsOneWidget);
  });

  testWidgets('shortcut collision blocks reassignment', (tester) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MacosTheme(
          data: buildMacosTheme(Theme.of(context).brightness),
          child: child!,
        ),
        home: Scaffold(body: KeyboardShortcutsSettings(controller: settings)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('⌘R').first);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    final refreshActivator =
        settings.shortcuts.shortcutConfig.bindings[AppShortcutAction
                .refreshDevices]!
            as SingleActivator;
    expect(refreshActivator.trigger, LogicalKeyboardKey.keyR);
    expect(refreshActivator.meta, isTrue);
    expect(
      find.textContaining('Shortcut already used by Toggle Recording'),
      findsOneWidget,
    );
  });

  testWidgets('settings chrome uses semantic surfaces in light mode', (
    tester,
  ) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    final theme = buildLightTheme();

    await tester.pumpWidget(
      buildTestApp(settings: settings, themeMode: ThemeMode.light),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final rail = tester.widget<Container>(
      find.byKey(const Key('settings_nav_rail')),
    );
    final header = tester.widget<Container>(
      find.byKey(const Key('settings_header')),
    );
    final content = tester.widget<Container>(
      find.byKey(const Key('settings_content_surface')),
    );

    expect(scaffold.backgroundColor, theme.scaffoldBackgroundColor);
    expect(rail.color, theme.appTokens.panelBackground);
    expect(header.color, theme.appTokens.toolbarOverlay);
    expect(content.color, Colors.transparent);
  });

  testWidgets('settings chrome uses semantic surfaces in dark mode', (
    tester,
  ) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    final theme = buildDarkTheme();

    await tester.pumpWidget(
      buildTestApp(settings: settings, themeMode: ThemeMode.dark),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final rail = tester.widget<Container>(
      find.byKey(const Key('settings_nav_rail')),
    );
    final header = tester.widget<Container>(
      find.byKey(const Key('settings_header')),
    );
    final content = tester.widget<Container>(
      find.byKey(const Key('settings_content_surface')),
    );
    final card = tester.widget<Card>(find.byType(Card).first);

    expect(scaffold.backgroundColor, theme.appTokens.outerBackground);
    expect(rail.color, theme.appTokens.editorChromeBackground);
    expect(header.color, theme.appTokens.editorChromeBackground);
    expect(content.color, theme.appTokens.editorChromeBackground);
    expect(card.color, theme.appTokens.editorChromeBackground);
  });

  testWidgets('/settings/storage route opens settings on Storage section', (
    tester,
  ) async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);

    await tester.pumpWidget(
      ChangeNotifierProvider<LicenseController>(
        create: (_) => LicenseController(),
        child: MaterialApp(
          initialRoute: AppSettingsView.storageRouteName,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: ThemeMode.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MacosTheme(
            data: buildMacosTheme(Theme.of(context).brightness),
            child: child!,
          ),
          routes: {
            AppSettingsView.storageRouteName: (context) => AppSettingsView(
              controller: settings,
              initialSection: SettingsSection.storage,
            ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StorageSettingsSection), findsOneWidget);
  });
}
