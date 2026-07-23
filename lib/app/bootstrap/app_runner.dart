import 'package:clingfy/app/bootstrap/app_providers.dart';
import 'package:clingfy/app/infrastructure/analytics/analytics_events.dart';
import 'package:clingfy/app/infrastructure/analytics/analytics_service.dart';
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

    // Anonymous product analytics — a no-op in debug runs / without a POSTHOG_TOKEN define, and
    // honors the "Share anonymous usage analytics" setting loaded just above. `internal`/`testMode`
    // are the owner-only exclusion + manual test channel (persisted setting OR the CLINGFY_INTERNAL
    // / CLINGFY_ANALYTICS_TEST env override; test mode also enables capture in debug).
    await ClingfyAnalytics.init(
      enabled: settingsController.workspace.shareUsageAnalytics,
      internal: settingsController.workspace.analyticsMarkInternal,
      testMode: settingsController.workspace.analyticsTestMode,
    );
    ClingfyAnalytics.capture(AnalyticsEvents.appLaunch);

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
