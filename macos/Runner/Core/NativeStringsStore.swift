import Foundation

/// A thread-safe cache for localized strings fetched from Flutter.
///
/// Native code (menu bar, accessibility descriptions) should use this
/// to get localized strings without blocking on Flutter calls.
final class NativeStringsStore {
  static let shared = NativeStringsStore()

  private var cache: [String: String] = [:]
  private let lock = NSLock()

  private init() {
    // Initialize with English fallbacks so we always have something to show
    initializeFallbacks()
  }

  // MARK: - Public API

  /// Updates the cache with strings from Flutter.
  /// Called when Flutter pushes new localized strings.
  func updateCache(_ strings: [String: String]) {
    lock.lock()
    defer { lock.unlock() }

    for (key, value) in strings {
      cache[key] = value
    }
  }

  /// Gets a localized string by key.
  /// Returns the cached value or English fallback if not available.
  func string(for key: String) -> String {
    lock.lock()
    defer { lock.unlock() }

    return cache[key] ?? fallback(for: key)
  }

  /// Convenience accessors for menu strings
  var menuStartRecording: String {
    string(for: NativeUIStringKey.menuStartRecording)
  }

  var menuStopRecording: String {
    string(for: NativeUIStringKey.menuStopRecording)
  }

  var menuOpenApp: String {
    string(for: NativeUIStringKey.menuOpenApp)
  }

  var menuQuit: String {
    string(for: NativeUIStringKey.menuQuit)
  }

  var accessibilityStartRecording: String {
    string(for: NativeUIStringKey.accessibilityStartRecording)
  }

  var accessibilityStopRecording: String {
    string(for: NativeUIStringKey.accessibilityStopRecording)
  }

  var recordingSelectedMicFallbackWarning: String {
    string(for: NativeUIStringKey.recordingSelectedMicFallbackWarning)
  }

  var recordingSelectedMicFallbackFailure: String {
    string(for: NativeUIStringKey.recordingSelectedMicFallbackFailure)
  }

  // MARK: - Private

  private func initializeFallbacks() {
    // Pre-populate with English fallbacks
    cache = [
      NativeUIStringKey.menuStartRecording: "Start Recording",
      NativeUIStringKey.menuStopRecording: "Stop Recording",
      NativeUIStringKey.menuOpenApp: "Open Clingfy",
      NativeUIStringKey.menuQuit: "Quit Clingfy",
      NativeUIStringKey.accessibilityStartRecording: "Start recording",
      NativeUIStringKey.accessibilityStopRecording: "Stop recording",
      NativeUIStringKey.recordingSelectedMicFallbackWarning:
        "Selected microphone couldn’t be used. Recording started with the system default microphone.",
      NativeUIStringKey.recordingSelectedMicFallbackFailure:
        "Selected microphone couldn’t be used for recording. Choose another microphone or turn microphone recording off.",
    ]
  }

  private func fallback(for key: String) -> String {
    switch key {
    case NativeUIStringKey.menuStartRecording:
      return "Start Recording"
    case NativeUIStringKey.menuStopRecording:
      return "Stop Recording"
    case NativeUIStringKey.menuOpenApp:
      return "Open Clingfy"
    case NativeUIStringKey.menuQuit:
      return "Quit Clingfy"
    case NativeUIStringKey.accessibilityStartRecording:
      return "Start recording"
    case NativeUIStringKey.accessibilityStopRecording:
      return "Stop recording"
    case NativeUIStringKey.recordingSelectedMicFallbackWarning:
      return "Selected microphone couldn’t be used. Recording started with the system default microphone."
    case NativeUIStringKey.recordingSelectedMicFallbackFailure:
      return "Selected microphone couldn’t be used for recording. Choose another microphone or turn microphone recording off."
    default:
      return key
    }
  }
}
