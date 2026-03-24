import 'package:flutter/material.dart';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/controllers/app_preferences_controller.dart';
import 'package:clingfy/app/settings/controllers/storage_settings_controller.dart';
import 'package:clingfy/core/export/settings/export_settings_controller.dart';
import 'package:clingfy/core/post_processing/settings/post_processing_settings_controller.dart';
import 'package:clingfy/core/recording/settings/recording_settings_controller.dart';
import 'package:clingfy/app/settings/controllers/shortcuts_settings_controller.dart';
import 'package:clingfy/app/settings/controllers/workspace_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:clingfy/app/settings/controllers/app_preferences_controller.dart'
    show AppLocaleSetting;

class SettingsController extends ChangeNotifier {
  SettingsController({required NativeBridge nativeBridge})
    : app = AppPreferencesController(),
      storage = StorageSettingsController(nativeBridge: nativeBridge),
      workspace = WorkspaceSettingsController(nativeBridge: nativeBridge),
      recording = RecordingSettingsController(nativeBridge: nativeBridge),
      export = ExportSettingsController(),
      post = PostProcessingSettingsController(),
      shortcuts = ShortcutsSettingsController() {
    for (final controller in [
      app,
      storage,
      workspace,
      recording,
      export,
      post,
      shortcuts,
    ]) {
      controller.addListener(notifyListeners);
    }
  }

  final AppPreferencesController app;
  final StorageSettingsController storage;
  final WorkspaceSettingsController workspace;
  final RecordingSettingsController recording;
  final ExportSettingsController export;
  final PostProcessingSettingsController post;
  final ShortcutsSettingsController shortcuts;

  @override
  void dispose() {
    for (final controller in [
      app,
      storage,
      workspace,
      recording,
      export,
      post,
      shortcuts,
    ]) {
      controller.removeListener(notifyListeners);
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await app.loadPreferences(prefs);
    await shortcuts.loadPreferences(prefs);
    await workspace.loadPreferences(prefs);
    await recording.loadPreferences(prefs);
    await export.loadPreferences(prefs);
    await post.loadPreferences(prefs);
    notifyListeners();
  }
}
