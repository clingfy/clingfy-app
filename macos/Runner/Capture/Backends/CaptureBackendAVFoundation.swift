//
//  CaptureBackendAVFoundation.swift
//  Runner
//
//  Created by Nabil Alhafez on 31/12/2025.
//

import AVFoundation
import CoreGraphics
import Foundation

/// AVFoundation backend implementation using the existing CapturePipeline (10.14+).
@MainActor
final class CaptureBackendAVFoundation: CaptureBackend {
  // MARK: CaptureBackend
  var onStarted: ((URL) -> Void)?
  var onFinished: ((URL?, Error?) -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?

  var isRecording: Bool {
    // AVCaptureMovieFileOutput reports recording state reliably.
    pipeline.movieOutput?.isRecording ?? false
  }

  var currentOutputURL: URL? {
    pipeline.movieOutput?.outputFileURL
  }

  // MARK: Internals
  private let pipeline: CapturePipeline

  init(pipeline: CapturePipeline = CapturePipeline()) {
    self.pipeline = pipeline

    // Bridge pipeline callbacks -> backend callbacks
    self.pipeline.onStarted = { [weak self] url in
      self?.onStarted?(url)
    }
    self.pipeline.onFinished = { [weak self] url, err in
      self?.onFinished?(url, err)
    }
  }

  func start(config: CaptureStartConfig) {
    pipeline.start(
      displayID: config.target.displayID,
      cropRect: config.target.cropRect,
      quality: config.quality,
      frameRate: config.frameRate,
      includeAudioDevice: config.includeAudioDevice,
      makeOutputURL: config.makeOutputURL
    )
  }

  func stop() {
    pipeline.stop()
  }

  func updateOverlay(windowID: CGWindowID?) {
    // AVFoundation captures the whole display area defined by cropRect.
    // The overlay is part of that area, so no specific logic is needed here.
  }
}
