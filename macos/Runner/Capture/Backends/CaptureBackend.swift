//
//  CaptureBackend.swift
//  Runner
//
//  Created by Nabil Alhafez on 31/12/2025.
//

import AVFoundation
import CoreGraphics
import Foundation

struct MicrophoneLevelSample {
  let linear: Double
  let dbfs: Double

  init(linear: Double, dbfs: Double) {
    self.linear = max(0.0, min(1.0, linear))
    self.dbfs = dbfs
  }

  var isLow: Bool {
    // Rough speech threshold for "quiet" input.
    dbfs < -32.0
  }
}

/// A backend-agnostic description of *what* we are capturing.
/// - AVFoundation backend uses: displayID + cropRect
/// - ScreenCaptureKit backend uses: windowID (for single-window) and may still need displayID for cursor normalization.
struct CaptureTarget: Equatable {
  let mode: DisplayTargetMode

  /// Always set. Used for:
  /// - AVFoundation display capture
  /// - CursorRecorder base display bounds fallback
  /// - Helpful logging / diagnostics
  let displayID: CGDirectDisplayID

  /// Used by AVFoundation backend (cropRect on AVCaptureScreenInput).
  /// For display capture: nil
  /// For area: non-nil
  /// For singleAppWindow fallback: non-nil
  let cropRect: CGRect?

  /// Used by ScreenCaptureKit backend for true window capture.
  /// Only meaningful for `.singleAppWindow`.
  let windowID: CGWindowID?

  init(
    mode: DisplayTargetMode,
    displayID: CGDirectDisplayID,
    cropRect: CGRect? = nil,
    windowID: CGWindowID? = nil
  ) {
    self.mode = mode
    self.displayID = displayID
    self.cropRect = cropRect
    self.windowID = windowID
  }
}

/// Inputs required to start a recording, independent of backend.
struct CaptureStartConfig {
  let target: CaptureTarget
  let quality: RecordingQuality
  let frameRate: Int

  /// Current AVFoundation pipeline accepts one selected audio device input.
  /// Current ScreenCaptureKit support maps this to microphone capture only.
  let includeAudioDevice: AVCaptureDevice?
  let includeSystemAudio: Bool

  /// Backend must call this to obtain the output URL
  /// so the save-folder/template logic stays owned by ScreenRecorderFacade.
  let makeOutputURL: () throws -> URL

  /// Whether to exclude the recorder app from screen capture.
  /// When true, the recorder window is hidden from recordings.
  /// When false, the recorder window appears in recordings.
  let excludeRecorderApp: Bool

  /// When true (and system audio is captured), tells SCKit to exclude the recorder process's
  /// own audio output from the system audio track — prevents mic/speaker feedback loops.
  let excludeMicFromSystemAudio: Bool

  /// The window ID of the camera overlay, if active.
  /// Used to ensure the overlay is included even if the rest of the app is excluded.
  let cameraOverlayWindowID: CGWindowID?

  init(
    target: CaptureTarget,
    quality: RecordingQuality,
    frameRate: Int,
    includeAudioDevice: AVCaptureDevice?,
    includeSystemAudio: Bool = false,
    makeOutputURL: @escaping () throws -> URL,
    excludeRecorderApp: Bool = false,
    cameraOverlayWindowID: CGWindowID? = nil,
    excludeMicFromSystemAudio: Bool = true
  ) {
    self.target = target
    self.quality = quality
    self.frameRate = frameRate
    self.includeAudioDevice = includeAudioDevice
    self.includeSystemAudio = includeSystemAudio
    self.makeOutputURL = makeOutputURL
    self.excludeRecorderApp = excludeRecorderApp
    self.cameraOverlayWindowID = cameraOverlayWindowID
    self.excludeMicFromSystemAudio = excludeMicFromSystemAudio
  }
}

/// Common interface for capture engines (AVFoundation vs ScreenCaptureKit).
///
/// Notes:
/// - `onStarted` and `onFinished` are required for our current ScreenRecorderFacade flow
///   (state transitions, indicator updates, overlay updates, Flutter callbacks). :contentReference[oaicite:1]{index=1}
/// - `currentOutputURL` is needed to preserve current "ALREADY_RECORDING returns path" behavior. :contentReference[oaicite:2]{index=2}
@MainActor
protocol CaptureBackend: AnyObject {
  var onStarted: ((URL) -> Void)? { get set }
  var onFinished: ((URL?, Error?) -> Void)? { get set }
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)? { get set }

  var isRecording: Bool { get }
  var currentOutputURL: URL? { get }

  func start(config: CaptureStartConfig)
  func stop()
  func updateOverlay(windowID: CGWindowID?)
}
