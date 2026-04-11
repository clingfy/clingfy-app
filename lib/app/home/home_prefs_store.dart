import 'dart:convert';

import 'package:clingfy/app/home/models/home_ui_prefs.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef HomePaneLayoutWarningLogger =
    void Function(Object error, StackTrace stackTrace);

class HomePrefsStore {
  HomePrefsStore({HomePaneLayoutWarningLogger? paneLayoutWarningLogger})
    : _paneLayoutWarningLogger =
          paneLayoutWarningLogger ?? _logPaneLayoutWarning;

  static const String indicatorPinnedKey = 'indicatorPinned';
  static const String displayTargetModeKey = 'displayTargetMode';
  static const String homePaneLayoutKey = 'homePaneLayoutV1';
  static const String homeGuidanceSeenKey = 'home_guidance_seen_v1';

  final HomePaneLayoutWarningLogger _paneLayoutWarningLogger;

  Future<HomeUiPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    final indicatorPinned = prefs.getBool(indicatorPinnedKey) ?? false;
    final rawMode =
        prefs.getInt(displayTargetModeKey) ??
        DisplayTargetMode.explicitId.index;
    final safeModeIndex =
        rawMode >= 0 && rawMode < DisplayTargetMode.values.length
        ? rawMode
        : DisplayTargetMode.explicitId.index;
    final rawPaneLayout = prefs.getString(homePaneLayoutKey);
    DesktopPaneLayoutPrefs paneLayout = kDefaultHomePaneLayoutPrefs;
    if (rawPaneLayout != null && rawPaneLayout.isNotEmpty) {
      try {
        paneLayout = _decodePaneLayout(jsonDecode(rawPaneLayout));
      } catch (error, stackTrace) {
        _paneLayoutWarningLogger(error, stackTrace);
        paneLayout = kDefaultHomePaneLayoutPrefs;
      }
    }

    return HomeUiPrefs(
      indicatorPinned: indicatorPinned,
      targetMode: DisplayTargetMode.values[safeModeIndex],
      paneLayout: paneLayout,
    );
  }

  Future<void> saveIndicatorPinned(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(indicatorPinnedKey, value);
  }

  Future<void> saveDisplayTargetMode(DisplayTargetMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(displayTargetModeKey, mode.index);
  }

  Future<void> savePaneLayout(DesktopPaneLayoutPrefs layout) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(homePaneLayoutKey, jsonEncode(layout.toJson()));
  }

  Future<bool> getGuideSeen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(homeGuidanceSeenKey) ?? false;
  }

  Future<void> setGuideSeen(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(homeGuidanceSeenKey, value);
  }

  static void _logPaneLayoutWarning(Object error, StackTrace stackTrace) {
    Log.w(
      'HomePrefsStore',
      'Failed to parse persisted home pane layout; falling back to defaults.',
      error,
      stackTrace,
    );
  }

  DesktopPaneLayoutPrefs _decodePaneLayout(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      throw const FormatException('Persisted pane layout must be an object.');
    }

    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException(
          'Persisted pane layout keys must be strings.',
        );
      }
      final isKnownPane = DesktopPaneId.values.any(
        (value) => value.name == key,
      );
      if (!isKnownPane) {
        continue;
      }
      if (!_isValidPaneStateObject(entry.value)) {
        throw FormatException(
          'Persisted pane layout for "$key" must be a pane state object.',
        );
      }
    }

    return DesktopPaneLayoutPrefs.fromJsonObject(raw);
  }

  bool _isValidPaneStateObject(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return false;
    }

    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) {
        return false;
      }
      final value = entry.value;
      if (key == 'width' || key == 'lastExpandedWidth') {
        if (value != null && value is! num) {
          return false;
        }
        continue;
      }
      if (key == 'isCollapsed' ||
          key == 'autoCollapseAllowed' ||
          key == 'userResized') {
        if (value != null && value is! bool) {
          return false;
        }
      }
    }

    return true;
  }
}
