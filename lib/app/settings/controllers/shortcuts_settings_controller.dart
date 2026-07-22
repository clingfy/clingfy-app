import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/app/settings/shortcuts/shortcut_config.dart';

class ShortcutsSettingsController extends ChangeNotifier {
  ShortcutConfig _shortcutConfig = ShortcutConfig.defaults;

  ShortcutConfig get shortcutConfig => _shortcutConfig;

  Future<void> loadPreferences(SharedPreferences prefs) async {
    final shortcutsJson = prefs.getString('shortcuts');
    if (shortcutsJson != null) {
      try {
        _shortcutConfig = ShortcutConfig.fromJson(jsonDecode(shortcutsJson));
      } catch (e, st) {
        Log.e('Settings', 'Error loading shortcuts', e, st);
      }
    }
    notifyListeners();
  }

  Future<void> updateShortcut(
    AppShortcutAction action,
    ShortcutActivator activator,
  ) async {
    final newBindings = Map<AppShortcutAction, ShortcutActivator>.from(
      _shortcutConfig.bindings,
    );
    newBindings[action] = activator;

    _shortcutConfig = ShortcutConfig(bindings: newBindings);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('shortcuts', jsonEncode(_shortcutConfig.toJson()));
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist shortcuts', e, st);
    }
  }
}
