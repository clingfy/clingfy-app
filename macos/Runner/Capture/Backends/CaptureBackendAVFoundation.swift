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
  var onPaused: (() -> Void)?
  var onResumed: (() -> Void)?
  var onWarning: ((String) -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?

  var canPauseResume: Bool { true }
  var supportsLiveOverlayExclusionDuringSeparateCameraCapture: Bool { false }
  var isRecording: Bool { pipeline.isRecording }

  var isPaused: Bool { pipeline.isRecordingPaused }

  var currentOutputURL: URL? { pipeline.currentOutputURL }

  // MARK: Internals
  private let pipeline: AVFoundationCapturePipelining

  init(pipeline: AVFoundationCapturePipelining = CapturePipeline()) {
    self.pipeline = pipeline

    // Bridge pipeline callbacks -> backend callbacks
    self.pipeline.onStarted = { [weak self] url in
      self?.onStarted?(url)
    }
    self.pipeline.onPaused = { [weak self] in
      self?.onPaused?()
    }
    self.pipeline.onResumed = { [weak self] in
      self?.onResumed?()
    }
    self.pipeline.onFinished = { [weak self] url, err in
      self?.onFinished?(url, err)
    }
    self.pipeline.onMicrophoneLevel = { [weak self] sample in
      self?.onMicrophoneLevel?(sample)
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

  func pause() {
    pipeline.pause()
  }

  func resume() {
    pipeline.resume()
  }

  func updateOverlay(windowID: CGWindowID?) {
    // AVFoundation captures the whole display area defined by cropRect.
    // The overlay is part of that area, so no specific logic is needed here.
  }
}
