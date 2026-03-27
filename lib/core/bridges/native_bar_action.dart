/// Action type strings for the pre-recording bar (native → Flutter communication).
///
/// IMPORTANT: Keep this in sync with `NativeBarAction.swift` on the native side.
abstract class NativeBarAction {
  NativeBarAction._();

  static const String closeTapped = 'closeTapped';
  static const String displayTapped = 'displayTapped';
  static const String windowTapped = 'windowTapped';
  static const String areaTapped = 'areaTapped';
  static const String cameraTapped = 'cameraTapped';
  static const String micTapped = 'micTapped';
  static const String systemAudioTapped = 'systemAudioTapped';
  static const String updateTapped = 'updateTapped';
  static const String recordTapped = 'recordTapped';
  static const String pauseTapped = 'pauseTapped';
  static const String resumeTapped = 'resumeTapped';
}

/// Selection type strings for native selection changes (native → Flutter).
///
/// IMPORTANT: Keep this in sync with `NativeSelectionType.swift` on the native side.
abstract class NativeSelectionType {
  NativeSelectionType._();

  static const String display = 'display';
  static const String window = 'window';
  static const String mic = 'mic';
  static const String camera = 'camera';
  static const String mode = 'mode';
}
