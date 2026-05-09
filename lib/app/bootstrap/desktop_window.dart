import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

const Size kDefaultDesktopWindowSize = Size(1280, 780);
const Size kMinimumDesktopWindowSize = Size(960, 640);

class DesktopWindow {
  const DesktopWindow._();

  static bool get _isDesktopHost {
    if (kIsWeb) return false;
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  /// Configure the desktop window with the standard Clingfy default + minimum
  /// size. No-op on mobile/web.
  static Future<void> configure() async {
    if (!_isDesktopHost) {
      return;
    }
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: kDefaultDesktopWindowSize,
      minimumSize: kMinimumDesktopWindowSize,
      center: true,
      title: 'Clingfy',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setMinimumSize(kMinimumDesktopWindowSize);
      await windowManager.show();
      await windowManager.focus();
    });
  }
}
