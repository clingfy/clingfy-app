/// Keys for native UI strings that are fetched from Flutter localization.
///
/// These are used by native macOS code (menu bar, etc.) to request
/// localized strings from Flutter.
///
/// IMPORTANT: Keep this in sync with `NativeUIStringKey.swift` on the native side.
abstract class NativeUIStringKey {
  NativeUIStringKey._();

  // Menu bar items
  static const String menuStartRecording = 'menu.startRecording';
  static const String menuStopRecording = 'menu.stopRecording';
  static const String menuOpenApp = 'menu.openApp';
  static const String menuQuit = 'menu.quit';

  // Accessibility descriptions
  static const String accessibilityStartRecording =
      'accessibility.startRecording';
  static const String accessibilityStopRecording =
      'accessibility.stopRecording';
  static const String recordingSelectedMicFallbackWarning =
      'recording.selectedMicFallbackWarning';
  static const String recordingSelectedMicFallbackFailure =
      'recording.selectedMicFallbackFailure';

  /// All keys that native code may request.
  static const List<String> allKeys = [
    menuStartRecording,
    menuStopRecording,
    menuOpenApp,
    menuQuit,
    accessibilityStartRecording,
    accessibilityStopRecording,
    recordingSelectedMicFallbackWarning,
    recordingSelectedMicFallbackFailure,
  ];
}
