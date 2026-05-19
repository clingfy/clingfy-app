import AVFoundation
import CoreGraphics
import Foundation

/// Pure pre-recording permission decisions, extracted out of the inline checks
/// in `ScreenRecorderFacade.startRecording` (Slice 3 / PR 14 of the strangler
/// refactor).
///
/// The service only *decides* — the facade keeps every side effect
/// (`CGRequestScreenCaptureAccess()`, `ensureAccessibilityAllowed`),
/// `finishStartWithError(...)`, and the early `return`, so flow/UI behavior is
/// unchanged. Low-storage stays in the facade's `preflightCaptureDestination`
/// (the pure policy was already extracted in Slice 1 as
/// `CaptureDestinationPreflightPolicy`). Engine-domain decisions; the OS
/// permission probes are the platform leaves (see windows-port-inventory §7).
enum RecordingPreflightService {

  /// `false` ⇒ the facade must request access + fail start.
  /// `preflight` is injectable so this is testable without real TCC.
  static func screenRecordingSatisfied(
    preflight: () -> Bool = {
      if #available(macOS 10.15, *) { return CGPreflightScreenCaptureAccess() }
      return true
    }
  ) -> Bool {
    preflight()
  }

  /// Mirrors the original: blocks only when a real microphone is selected
  /// (not disabled, not empty, not "__none__") and not authorized.
  static func microphoneSatisfied(
    disableMicrophone: Bool,
    audioDeviceId: String?,
    audioAuthorized: Bool
  ) -> Bool {
    guard !disableMicrophone,
      let id = audioDeviceId,
      !id.isEmpty,
      id != "__none__"
    else { return true }
    return audioAuthorized
  }

  /// `true` ⇒ accessibility is required for the recording-linked cursor and is
  /// not granted ⇒ the facade must fail start.
  static func accessibilityBlocksRecording(
    cursorEnabledForRecording: Bool,
    cursorLinked: Bool,
    accessibilityAllowed: Bool
  ) -> Bool {
    cursorEnabledForRecording && cursorLinked && !accessibilityAllowed
  }
}
