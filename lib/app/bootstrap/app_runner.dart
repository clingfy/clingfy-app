import 'package:clingfy/app/bootstrap/app_providers.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/shell/platform_app.dart';
import 'package:flutter/widgets.dart';

class AppRunner {
  static Future<void> run({RemoteLogSink? remoteLogSink}) async {
    await Log.init(remoteSink: remoteLogSink);

    final nativeBridge = NativeBridge.instance;
    final settingsController = SettingsController(nativeBridge: nativeBridge);
    await settingsController.loadPreferences();

    runApp(
      AppProviders(
        settingsController: settingsController,
        nativeBridge: nativeBridge,
        child: PlatformApp(
          settingsController: settingsController,
          nativeBridge: nativeBridge,
        ),
      ),
    );
  }
}
