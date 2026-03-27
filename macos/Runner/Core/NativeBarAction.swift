import Foundation

/// Action type strings for the pre-recording bar (native → Flutter communication).
///
/// IMPORTANT: Keep this in sync with `native_bar_action.dart` on the Flutter side.
enum NativeBarAction {
  static let closeTapped = "closeTapped"
  static let displayTapped = "displayTapped"
  static let windowTapped = "windowTapped"
  static let areaTapped = "areaTapped"
  static let cameraTapped = "cameraTapped"
  static let micTapped = "micTapped"
  static let systemAudioTapped = "systemAudioTapped"
  static let updateTapped = "updateTapped"
  static let recordTapped = "recordTapped"
  static let pauseTapped = "pauseTapped"
  static let resumeTapped = "resumeTapped"
}

/// Selection type strings for native selection changes (native → Flutter).
///
/// IMPORTANT: Keep this in sync with `native_bar_action.dart` on the Flutter side.
enum NativeSelectionType {
  static let display = "display"
  static let window = "window"
  static let mic = "mic"
  static let camera = "camera"
  static let mode = "mode"
}

/// Device event types for the EventChannel.
///
/// IMPORTANT: Keep this in sync with `native_method_channel.dart` on the Flutter side.
enum DeviceEventType {
  static let audioSourcesChanged = "audioSourcesChanged"
  static let videoSourcesChanged = "videoSourcesChanged"
  static let microphoneLevel = "microphoneLevel"
}
