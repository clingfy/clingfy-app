import Foundation

/// A thread-safe cache for localized strings fetched from Flutter.
///
/// Native code (menu bar, accessibility descriptions) should use this
/// to get localized strings without blocking on Flutter calls.
final class NativeStringsStore {
  static let shared = NativeStringsStore()
  private static let fallbackStrings: [String: String] = [
    NativeUIStringKey.menuStartRecording: "Start Recording",
    NativeUIStringKey.menuStopRecording: "Stop Recording",
    NativeUIStringKey.menuOpenApp: "Open Clingfy",
    NativeUIStringKey.menuQuit: "Quit Clingfy",
    NativeUIStringKey.accessibilityStartRecording: "Start Recording",
    NativeUIStringKey.accessibilityStopRecording: "Stop Recording",
    NativeUIStringKey.recordingSelectedMicFallbackWarning:
      "Selected microphone couldn’t be used. Recording started with the system default microphone.",
    NativeUIStringKey.recordingSelectedMicFallbackFailure:
      "Selected microphone couldn’t be used for recording. Choose another microphone or turn microphone recording off.",
    NativeUIStringKey.preRecordingBarDisplay: "Display",
    NativeUIStringKey.preRecordingBarWindow: "Window",
    NativeUIStringKey.preRecordingBarArea: "Area",
    NativeUIStringKey.preRecordingBarCamera: "Camera",
    NativeUIStringKey.preRecordingBarMic: "Mic",
    NativeUIStringKey.preRecordingBarSystem: "System",
    NativeUIStringKey.preRecordingBarUpdate: "Update",
    NativeUIStringKey.preRecordingBarPause: "PAUSE",
    NativeUIStringKey.preRecordingBarResume: "RESUME",
    NativeUIStringKey.preRecordingBarNone: "None",
    NativeUIStringKey.preRecordingBarRefresh: "Refresh",
    NativeUIStringKey.preRecordingBarSelectDisplay: "Select Display",
    NativeUIStringKey.preRecordingBarSelectWindow: "Select Window",
    NativeUIStringKey.preRecordingBarSelectMicrophone: "Select Microphone",
    NativeUIStringKey.preRecordingBarSelectCamera: "Select Camera",
    NativeUIStringKey.preRecordingBarUnknownDisplay: "Unknown Display",
    NativeUIStringKey.preRecordingBarUnknownWindow: "Unknown Window",
    NativeUIStringKey.preRecordingBarUnknownMic: "Unknown Mic",
    NativeUIStringKey.preRecordingBarUnknownCamera: "Unknown Camera",
    NativeUIStringKey.preRecordingBarNoCamera: "No camera",
    NativeUIStringKey.preRecordingBarDoNotRecordAudio: "Do not record audio",
    NativeUIStringKey.displayServiceScreen: "Screen",
    NativeUIStringKey.displayServiceApp: "App",
    NativeUIStringKey.recordingIndicatorStopping: "Stopping...",
    NativeUIStringKey.recordingIndicatorPauseRecording: "Pause recording",
    NativeUIStringKey.recordingIndicatorResumeRecording: "Resume recording",
    NativeUIStringKey.recordingIndicatorInProgressLabel: "Recording in progress",
    NativeUIStringKey.recordingIndicatorPausedLabel: "Recording paused",
    NativeUIStringKey.recordingIndicatorStoppingRecording: "Stopping recording",
    NativeUIStringKey.recordingIndicatorHelpPause:
      "Primary action pauses recording. Secondary stop control stops recording.",
    NativeUIStringKey.recordingIndicatorHelpResume:
      "Primary action resumes recording. Secondary stop control stops recording.",
    NativeUIStringKey.recordingIndicatorHelpStopping: "Recording is stopping.",
  ]

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
    cache = Self.fallbackStrings
  }

  private func fallback(for key: String) -> String {
    Self.fallbackStrings[key] ?? key
  }

  #if DEBUG
    func resetForTesting() {
      lock.lock()
      defer { lock.unlock() }
      cache = Self.fallbackStrings
    }
  #endif
  }
}
