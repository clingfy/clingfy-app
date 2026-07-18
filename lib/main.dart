import 'package:clingfy/app/bootstrap/app_bootstrap.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';

/// Compile-time gate that lets agent tooling (the Dart & Flutter MCP server)
/// drive the app via `flutter_driver_command`. Off unless the app is launched
/// with `--dart-define=ENABLE_FLUTTER_DRIVER=true`, so release builds
/// tree-shake the driver extension entirely.
const bool _enableFlutterDriver = bool.fromEnvironment('ENABLE_FLUTTER_DRIVER');

Future<void> main() async {
  if (_enableFlutterDriver) {
    // Installs its own WidgetsBinding, so it must run before
    // ensureInitialized() — the driver binding cannot replace an existing one.
    enableFlutterDriverExtension();
  }
  WidgetsFlutterBinding.ensureInitialized();
  await AppBootstrap.run();
}
