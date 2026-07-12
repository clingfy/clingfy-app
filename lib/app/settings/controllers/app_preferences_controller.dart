import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/core/logging/logger_service.dart';

enum AppLocaleSetting { system, en, ar, ro }

class AppPreferencesController extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  AppLocaleSetting _localeSetting = AppLocaleSetting.system;

  ThemeMode get themeMode => _themeMode;
  AppLocaleSetting get localeSetting => _localeSetting;

  Locale? get locale {
    switch (_localeSetting) {
      case AppLocaleSetting.system:
        return null;
      case AppLocaleSetting.en:
        return const Locale('en');
      case AppLocaleSetting.ar:
        return const Locale('ar');
      case AppLocaleSetting.ro:
        return const Locale('ro');
    }
  }

  Future<void> loadPreferences(SharedPreferences prefs) async {
    final themeName = prefs.getString('themeMode');
    if (themeName != null) {
      _themeMode = ThemeMode.values.firstWhere(
        (e) => e.name == themeName,
        orElse: () => ThemeMode.system,
      );
    }

    final localeName = prefs.getString('appLocale');
    if (localeName != null) {
      _localeSetting = AppLocaleSetting.values.firstWhere(
        (e) => e.name == localeName,
        orElse: () => AppLocaleSetting.system,
      );
    }

    notifyListeners();
  }

  Future<void> updateThemeMode(ThemeMode? newThemeMode) async {
    if (newThemeMode == null || newThemeMode == _themeMode) return;

    _themeMode = newThemeMode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('themeMode', newThemeMode.name);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist theme mode', e, st);
    }
  }

  Future<void> updateLocale(AppLocaleSetting? newLocale) async {
    if (newLocale == null || newLocale == _localeSetting) return;

    _localeSetting = newLocale;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('appLocale', newLocale.name);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist locale', e, st);
    }
  }
}
