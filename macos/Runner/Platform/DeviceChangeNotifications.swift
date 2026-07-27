import Foundation

/// Fan-out for device-list changes.
///
/// The facade's `onDevicesChanged` / `onDisplaysChanged` / … callbacks are
/// single-assignment and already owned by `ScreenRecorderEventBridge`, which
/// forwards them to Flutter. The native pre-recording bar needs the same
/// signals, and a second consumer cannot simply take the callback — it would
/// silently unhook Flutter.
///
/// So changes are also posted as notifications: any number of observers, no
/// ownership question, and the existing Flutter path is untouched.
extension Notification.Name {
  static let deviceAudioSourcesChanged = Notification.Name("clingfy.deviceChange.audioSources")
  static let deviceVideoSourcesChanged = Notification.Name("clingfy.deviceChange.videoSources")
  static let deviceDisplaysChanged = Notification.Name("clingfy.deviceChange.displays")
  static let deviceAppWindowsChanged = Notification.Name("clingfy.deviceChange.appWindows")
}

enum DeviceChangeNotification {

  /// Every observer of these updates AppKit views, so delivery is always on
  /// the main queue regardless of which thread the change was detected on —
  /// the CoreAudio HAL and the capture queues both report off-main.
  static func post(_ name: Notification.Name) {
    if Thread.isMainThread {
      NotificationCenter.default.post(name: name, object: nil)
    } else {
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: name, object: nil)
      }
    }
  }
}
