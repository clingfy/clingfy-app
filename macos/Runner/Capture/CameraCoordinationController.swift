import AVFoundation
import CoreMedia
import FlutterMacOS
import Foundation

/// Slice 4 / PR 16: owns the small separate-camera recording session state
/// previously held inline on `ScreenRecorderFacade` — the in-flight
/// `pendingCameraRecordingSession` + the first-failure latch
/// `pendingSeparateCameraFailure` — and the four pure helpers that read from
/// `AVCaptureDevice` / `PreferencesStore` to materialise a recording session
/// or its manifest sidecar.
///
/// The controller does NOT own `CameraRecorder`, `capture`, `state`, or any
/// of the `runOnMainIfNeeded(...)` / `finishStartWithError(...)` /
/// `beginStoppingCapture()` side effects: those continue to live on the facade
/// (`handleSeparateCameraRecorderFailure(_:)` keeps the state-machine
/// transitions; only the failure-dedup primitive and the stored-failure read
/// move here). Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
final class CameraCoordinationController {

  /// In-flight recording session for a separate-camera asset, or `nil` when
  /// the current/next recording is screen-only.
  private(set) var pendingRecordingSession: CameraRecordingSession?

  /// First fatal failure reported by the separate-camera recorder during the
  /// current start/recording cycle. Latched so the screen recorder can decide
  /// whether to bubble it up over the screen-side error.
  private(set) var pendingFailure: FlutterError?

  func setPendingRecordingSession(_ session: CameraRecordingSession?) {
    pendingRecordingSession = session
  }

  func clearPendingFailure() {
    pendingFailure = nil
  }

  /// Returns `true` iff this is the first separate-camera failure of the
  /// current cycle (caller proceeds with state transitions). Subsequent
  /// failures are observed but suppressed so the screen-side error wins.
  /// Mirrors the old `guard pendingSeparateCameraFailure == nil else { return }`
  /// pattern in `handleSeparateCameraRecorderFailure(_:)`.
  func storeFailureIfFirst(_ error: FlutterError) -> Bool {
    guard pendingFailure == nil else { return false }
    pendingFailure = error
    return true
  }

  /// Pure: screen-side error wins; otherwise surface the latched separate-camera
  /// failure. Verbatim from `terminalRecordingError(screenError:)`.
  func terminalRecordingError(screenError: Error?) -> Error? {
    if let screenError {
      return screenError
    }
    return pendingFailure
  }

  // MARK: - Pure factories (lifted verbatim from the facade)

  func recordingDimensions(deviceID: String?) -> CameraRecordingMetadata.Dimensions? {
    let device =
      deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
      ?? AVCaptureDevice.default(for: .video)
    guard let device else { return nil }
    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    return CameraRecordingMetadata.Dimensions(
      width: Int(dimensions.width),
      height: Int(dimensions.height)
    )
  }

  func nominalFrameRate(deviceID: String?) -> Double? {
    let device =
      deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
      ?? AVCaptureDevice.default(for: .video)
    guard let device else { return nil }
    if device.activeVideoMinFrameDuration.isNumeric,
      device.activeVideoMinFrameDuration.seconds > 0
    {
      return 1.0 / device.activeVideoMinFrameDuration.seconds
    }
    return device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
  }

  func makeRecordingSession(
    projectRoot: URL,
    deviceId: String?,
    mirrored: Bool
  ) -> CameraRecordingSession {
    CameraRecordingSession(
      outputURL: RecordingProjectPaths.cameraRawURL(for: projectRoot),
      metadataURL: RecordingProjectPaths.cameraMetadataURL(for: projectRoot),
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      segmentDirectoryURL: RecordingProjectPaths.cameraSegmentsDirectoryURL(for: projectRoot),
      deviceId: deviceId,
      mirroredRaw: mirrored,
      nominalFrameRate: nominalFrameRate(deviceID: deviceId),
      dimensions: recordingDimensions(deviceID: deviceId)
    )
  }

  func makeCaptureInfo(
    projectRoot: URL?,
    shouldRecordSeparateCameraAsset: Bool,
    deviceId: String?,
    mirrored: Bool
  ) -> RecordingMetadata.CameraCaptureInfo? {
    guard shouldRecordSeparateCameraAsset, projectRoot != nil else { return nil }
    return RecordingMetadata.CameraCaptureInfo(
      mode: .separateCameraAsset,
      enabled: true,
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      deviceId: deviceId,
      mirroredRaw: mirrored,
      nominalFrameRate: nominalFrameRate(deviceID: deviceId),
      dimensions: recordingDimensions(deviceID: deviceId).map {
        RecordingMetadata.Dimensions(width: $0.width, height: $0.height)
      },
      segments: []
    )
  }
}
