import 'package:clingfy/app/bootstrap/app_runner.dart';
import 'package:clingfy/app/bootstrap/desktop_window.dart';
import 'package:clingfy/app/infrastructure/error/global_error_handlers.dart';
import 'package:clingfy/app/infrastructure/observability/sentry_setup.dart';

class AppBootstrap {
  static Future<void> run() async {
    GlobalErrorHandlers.install();
    await DesktopWindow.configure();
    await SentrySetup.run(appRunner: AppRunner.run);
  }
}
