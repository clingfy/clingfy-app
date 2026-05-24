import AVFoundation
import CoreGraphics
import Foundation

/// Slice 7 / PR 25: stateless builder that turns the per-session inputs the
/// facade has at `startCapture` time into a `CaptureStartConfig`. Extracts
/// the body of the old facade-private `makeCaptureStartConfig(...)` +
/// `resolveAudioDevice(...)` so the configuration shape can be unit-tested
/// independently of the recorder lifecycle.
///
/// The builder owns no state; every value it needs is in the `Input` struct.
/// `quality` is hardcoded to `.native` to preserve PR-25-era behavior —
/// adding a quality input is a future enhancement when the rest of the
/// pipeline actually threads it through.
///
/// What stays on the facade (these all move in PR 26, not here):
/// - `pendingStartCaptureConfig = cfg`
/// - `capture.start(config: cfg)`
/// - `effectiveOverlayID` calculation
/// - `suppressOverlayWindowDuringSeparateCameraCapture` assignment
/// - `updateOverlayVisibility()`
///
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
struct CaptureStartConfigBuilder {

  struct Input {
    let target: CaptureTarget
    let frameRate: Int
    let outputURL: () throws -> URL
    let effectiveOverlayID: CGWindowID?
    let systemAudioEnabled: Bool

    let audioDeviceID: String?
    let disableMicrophone: Bool
    let excludeRecorderApp: Bool
    let shouldRecordSeparateCameraAsset: Bool
    let excludeMicFromSystemAudio: Bool
  }

  /// Verbatim from the old facade-private `makeCaptureStartConfig(...)`:
  /// fixed `.native` quality; mic device resolved via `resolveAudioDevice`;
  /// `cameraOverlayWindowID` always carries `effectiveOverlayID`, while
  /// `excludeCameraOverlayWindow` follows `shouldRecordSeparateCameraAsset`
  /// — backends that support live overlay exclusion read both together.
  /// `makeOutputURL` is threaded through as the lazy `outputURL` closure
  /// (the URL isn't materialised here; backends call it when they're
  /// actually ready to write).
  func build(_ input: Input) -> CaptureStartConfig {
    CaptureStartConfig(
      target: input.target,
      quality: .native,
      frameRate: input.frameRate,
      includeAudioDevice: resolveAudioDevice(
        audioDeviceID: input.audioDeviceID,
        disableMicrophone: input.disableMicrophone),
      includeSystemAudio: input.systemAudioEnabled,
      makeOutputURL: input.outputURL,
      excludeRecorderApp: input.excludeRecorderApp,
      cameraOverlayWindowID: input.effectiveOverlayID,
      excludeCameraOverlayWindow: input.shouldRecordSeparateCameraAsset,
      excludeMicFromSystemAudio: input.excludeMicFromSystemAudio
    )
  }

  /// Verbatim from the old facade-private `resolveAudioDevice(disable
  /// Microphone:)`: audio input is optional, so the gate is "real mic
  /// selected and not disabled". `nil` / empty / `"__none__"` all collapse
  /// to "no audio device". When a real UID is supplied, `AVCaptureDevice
  /// (uniqueID:)` returns `nil` for unknown devices (system call, but
  /// deterministic + side-effect-free + no permission required).
  func resolveAudioDevice(
    audioDeviceID: String?,
    disableMicrophone: Bool
  ) -> AVCaptureDevice? {
    guard !disableMicrophone else { return nil }
    guard let id = audioDeviceID, !id.isEmpty, id != "__none__" else { return nil }
    return AVCaptureDevice(uniqueID: id)
  }
}
