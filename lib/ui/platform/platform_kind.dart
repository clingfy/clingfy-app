import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

enum PlatformKind { macos, windows, web, linux, other }

/// Test-only override so widget tests can pin BOTH platform branches of a
/// forked UI regardless of the host OS the test runner happens to be on
/// (dart:io Platform cannot be faked). Production code never sets this.
PlatformKind? debugPlatformKindOverride;

bool isWindows() {
  return !kIsWeb && currentPlatformKind() == PlatformKind.windows;
}

bool isMac() {
  return !kIsWeb && currentPlatformKind() == PlatformKind.macos;
}

PlatformKind currentPlatformKind() {
  if (debugPlatformKindOverride != null) {
    return debugPlatformKindOverride!;
  }
  if (Platform.isMacOS) {
    return PlatformKind.macos;
  }
  if (Platform.isWindows) {
    return PlatformKind.windows;
  }
  if (kIsWeb) {
    return PlatformKind.other;
  }
  return PlatformKind.other;
}
