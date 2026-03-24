import 'package:clingfy/app/shell/app_scope.dart';
import 'package:clingfy/app/home/home_page.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/widgets/about_view.dart';
import 'package:clingfy/app/settings/widgets/app_settings_view.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:clingfy/app/permissions/widgets/permissions_gate.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:clingfy/ui/platform/platform_kind.dart';

class PlatformApp extends StatelessWidget {
  const PlatformApp({
    super.key,
    required this.settingsController,
    required this.nativeBridge,
  });

  final SettingsController settingsController;
  final NativeBridge nativeBridge;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsController,
      builder: (context, _) {
        final lightTheme = buildLightTheme();
        final darkTheme = buildDarkTheme();

        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: settingsController.app.themeMode,
          locale: settingsController.app.locale,
          localizationsDelegates: [
            ...AppLocalizations.localizationsDelegates,
            fluent.FluentLocalizations.delegate,
          ],
          supportedLocales: {
            ...AppLocalizations.supportedLocales,
            ...fluent.FluentLocalizations.supportedLocales,
          }.toList(),
          builder: (context, child) {
            final safeChild = child ?? const SizedBox.shrink();
            final isDark = Theme.of(context).brightness == Brightness.dark;

            if (isMac()) {
              return MacosTheme(
                data: buildMacosTheme(
                  isDark ? Brightness.dark : Brightness.light,
                ),
                child: safeChild,
              );
            }

            if (isWindows()) {
              return fluent.FluentTheme(
                data: buildFluentTheme(
                  isDark ? Brightness.dark : Brightness.light,
                ),
                child: safeChild,
              );
            }

            return safeChild;
          },
          home: Builder(
            builder: (context) {
              return PermissionsGate(
                nativeBridge: nativeBridge,
                child: HomePage(
                  title: AppLocalizations.of(context)!.appTitleFull,
                  appScope: AppScope(
                    nativeBridge: nativeBridge,
                    settings: settingsController,
                  ),
                ),
              );
            },
          ),
          routes: {
            AppSettingsView.routeName: (context) =>
                AppSettingsView(controller: settingsController),
            AppSettingsView.storageRouteName: (context) => AppSettingsView(
              controller: settingsController,
              initialSection: SettingsSection.storage,
            ),
            AboutView.routeName: (context) => AppSettingsView(
              controller: settingsController,
              initialSection: SettingsSection.about,
            ),
          },
        );
      },
    );
  }
}
