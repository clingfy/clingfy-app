//
//  CaptureBackendScreenCaptureKit.swift
//  Runner
//
//  Created by Nabil Alhafez on 31/12/2025.
//  True window capture backend (macOS 15+ because it uses SCRecordingOutput).
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo  // : Needed for kCVPixelFormatType
import Foundation
import QuartzCore
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

private func temporaryCursorSegmentURL(for videoURL: URL) -> URL {
  videoURL.deletingPathExtension().appendingPathExtension("cursor.json")
}

private func finalCursorDataURL(for videoURL: URL) -> URL {
  RecordingProjectPaths.resolvedCursorDataURL(forScreenVideoURL: videoURL)
}

struct TerminalCompletionGuard {
  private(set) var didComplete = false

  mutating func beginCompletion() -> Bool {
    if didComplete {
      return false
    }

    didComplete = true
    return true
  }

  mutating func reset() {
    didComplete = false
  }
}

struct CursorFailureFinalizationPlan {
  let cursorURL: URL?
  let shouldFlushCursor: Bool

  static func make(recordingURL: URL?, cursorCaptureActive: Bool) -> CursorFailureFinalizationPlan {
    let cursorURL = recordingURL.map { finalCursorDataURL(for: $0) }
    return CursorFailureFinalizationPlan(
      cursorURL: cursorURL,
      shouldFlushCursor: cursorCaptureActive && cursorURL != nil
    )
  }
}

private final class RecordingOutputFinalizationWaiter {
  private var result: Result<Void, Error>?
  private var continuations: [CheckedContinuation<Void, Error>] = []

  func wait() async throws {
    if let result {
      return try result.get()
    }

    try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func succeed() {
    resolve(.success(()))
  }

  func fail(_ error: Error) {
    resolve(.failure(error))
  }

  private func resolve(_ result: Result<Void, Error>) {
    guard self.result == nil else { return }
    self.result = result
    let continuations = self.continuations
    self.continuations.removeAll()
    for continuation in continuations {
      continuation.resume(with: result)
    }
  }
}

private struct SegmentedRecordingArtifact {
  let index: Int
  let rawURL: URL
  let cursorURL: URL?
  let recordedDuration: TimeInterval
  let startWallClock: Date
  let endWallClock: Date
}

private struct SegmentedRecordingSession {
  let primaryInProgressRawURL: URL
  let expectsCursorSidecars: Bool
  private(set) var segmentArtifacts: [SegmentedRecordingArtifact] = []
  private(set) var cumulativeRecordedDuration: TimeInterval = 0
  private var nextSegmentIndex: Int = 0

  init(primaryInProgressRawURL: URL, expectsCursorSidecars: Bool) {
    self.primaryInProgressRawURL = primaryInProgressRawURL
    self.expectsCursorSidecars = expectsCursorSidecars
  }

  mutating func nextSegmentURLs() -> (index: Int, rawURL: URL, cursorURL: URL?) {
    nextSegmentIndex += 1
    let index = nextSegmentIndex
    let stem = primaryInProgressRawURL.deletingPathExtension().lastPathComponent
    let ext = primaryInProgressRawURL.pathExtension.isEmpty ? "mov" : primaryInProgressRawURL.pathExtension
    let rawURL = primaryInProgressRawURL.deletingLastPathComponent().appendingPathComponent(
      "\(stem).segment-\(String(format: "%03d", index)).\(ext)"
    )
    return (
      index: index,
      rawURL: rawURL,
      cursorURL: expectsCursorSidecars ? temporaryCursorSegmentURL(for: rawURL) : nil
    )
  }

  mutating func appendSegment(
    index: Int,
    rawURL: URL,
    cursorURL: URL?,
    recordedDuration: TimeInterval,
    startWallClock: Date,
    endWallClock: Date
  ) {
    let artifact = SegmentedRecordingArtifact(
      index: index,
      rawURL: rawURL,
      cursorURL: cursorURL,
      recordedDuration: recordedDuration,
      startWallClock: startWallClock,
      endWallClock: endWallClock
    )
    segmentArtifacts.append(artifact)
    cumulativeRecordedDuration += recordedDuration
  }

  var recordedScreenSegments: [RecordingMetadata.CaptureSegment] {
    segmentArtifacts
      .sorted(by: { $0.index < $1.index })
      .map { artifact in
        RecordingMetadata.CaptureSegment(
          index: artifact.index,
          relativePath: artifact.rawURL.lastPathComponent,
          startWallClock: RecordingMetadata.iso8601String(from: artifact.startWallClock),
          endWallClock: RecordingMetadata.iso8601String(from: artifact.endWallClock),
          durationSeconds: artifact.recordedDuration
        )
      }
  }
}

@available(macOS 15.0, *)
private final class RecordingSegmentContext {
  let index: Int
  let rawURL: URL
  let cursorURL: URL?
  let recordingOutput: SCRecordingOutput
  let startedAt: Date
  let finalizationWaiter = RecordingOutputFinalizationWaiter()

  init(
    index: Int,
    rawURL: URL,
    cursorURL: URL?,
    recordingOutput: SCRecordingOutput,
    startedAt: Date = Date()
  ) {
    self.index = index
    self.rawURL = rawURL
    self.cursorURL = cursorURL
    self.recordingOutput = recordingOutput
    self.startedAt = startedAt
  }
}

private struct CursorSpriteSignature: Hashable {
  let width: Int
  let height: Int
  let hotspotXBits: UInt64
  let hotspotYBits: UInt64
  let pixels: Data

  init(sprite: CursorSprite) {
    width = sprite.width
    height = sprite.height
    hotspotXBits = sprite.hotspotX.bitPattern
    hotspotYBits = sprite.hotspotY.bitPattern
    pixels = sprite.pixels
  }
}

private final class AssetExportSessionBox: @unchecked Sendable {
  let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }
}

enum ScreenCaptureKitOverlayFilterPolicy {
  struct WindowRecord: Equatable {
    let windowID: CGWindowID
    let bundleIdentifier: String?
  }

  static func excludedWindowIDs(
    windows: [WindowRecord],
    selfBundleIdentifier: String?,
    overlayWindowID: CGWindowID?,
    excludeRecorderApp: Bool,
    excludeCameraOverlayWindow: Bool
  ) -> [CGWindowID] {
    var excluded = Set<CGWindowID>()

    if excludeRecorderApp, let selfBundleIdentifier {
      for window in windows where window.bundleIdentifier == selfBundleIdentifier {
        if !excludeCameraOverlayWindow,
          let overlayWindowID,
          window.windowID == overlayWindowID
        {
          continue
        }
        excluded.insert(window.windowID)
      }
    }

    if excludeCameraOverlayWindow, let overlayWindowID {
      excluded.insert(overlayWindowID)
    }

    return excluded.sorted()
  }
}

private enum RecordingSegmentMerger {
  static func mergeSegments(
    _ segmentURLs: [URL],
    to outputURL: URL,
    fileManager: FileManager = .default
  ) async throws -> URL {
    guard !segmentURLs.isEmpty else {
      throw flutterError(NativeErrorCode.videoFileMissing, "No recording segments to merge")
    }

    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }

    if segmentURLs.count == 1 {
      try fileManager.moveItem(at: segmentURLs[0], to: outputURL)
      return outputURL
    }

    let composition = AVMutableComposition()
    var cursorTime = CMTime.zero
    var compositionTracks: [String: AVMutableCompositionTrack] = [:]

    for segmentURL in segmentURLs {
      let asset = AVURLAsset(url: segmentURL)
      let duration = asset.duration

      for (type, prefix) in [(AVMediaType.video, "video"), (AVMediaType.audio, "audio")] {
        let tracks = asset.tracks(withMediaType: type)
        for (index, track) in tracks.enumerated() {
          let key = "\(prefix)-\(index)"
          let compositionTrack =
            compositionTracks[key]
            ?? composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
          guard let compositionTrack else {
            throw flutterError(
              NativeErrorCode.recordingError,
              "Unable to create composition track for merged recording"
            )
          }
          compositionTracks[key] = compositionTrack
          try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: track,
            at: cursorTime
          )
          if type == .video && compositionTrack.preferredTransform == .identity {
            compositionTrack.preferredTransform = track.preferredTransform
          }
        }
      }

      cursorTime = cursorTime + duration
    }

    let presetNames = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
    var lastError: Error?

    for presetName in presetNames {
      guard let export = AVAssetExportSession(asset: composition, presetName: presetName) else {
        continue
      }
      let exportBox = AssetExportSessionBox(export)

      export.outputURL = outputURL
      export.outputFileType = .mov
      export.shouldOptimizeForNetworkUse = false

      do {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          export.exportAsynchronously {
            let export = exportBox.session
            switch export.status {
            case .completed:
              continuation.resume(returning: ())
            case .failed:
              continuation.resume(
                throwing: export.error
                  ?? flutterError(NativeErrorCode.recordingError, "Segment merge failed")
              )
            case .cancelled:
              continuation.resume(
                throwing: flutterError(NativeErrorCode.recordingError, "Segment merge cancelled")
              )
            default:
              continuation.resume(
                throwing: flutterError(NativeErrorCode.recordingError, "Segment merge incomplete")
              )
            }
          }
        }
        return outputURL
      } catch {
        lastError = error
        if fileManager.fileExists(atPath: outputURL.path) {
          try? fileManager.removeItem(at: outputURL)
        }
      }
    }

    throw lastError
      ?? flutterError(NativeErrorCode.recordingError, "Unable to create export session for merged recording")
  }
}

private enum CursorSegmentMerger {
  static func mergeSegments(
    _ segments: [SegmentedRecordingArtifact],
    expectsCursorSidecars: Bool,
    outputURL: URL,
    fileManager: FileManager = .default
  ) throws {
    guard expectsCursorSidecars else { return }

    var mergedSprites: [CursorSprite] = []
    var mergedFrames: [CursorFrame] = []
    var spriteMap: [CursorSpriteSignature: Int] = [:]
    var timeOffset: TimeInterval = 0

    for segment in segments.sorted(by: { $0.index < $1.index }) {
      guard let cursorURL = segment.cursorURL else {
        throw flutterError(
          NativeErrorCode.cursorFileMissing,
          "Missing cursor sidecar path for segment \(segment.index)"
        )
      }
      guard fileManager.fileExists(atPath: cursorURL.path) else {
        throw flutterError(
          NativeErrorCode.cursorFileMissing,
          "Missing cursor sidecar for segment \(segment.index)"
        )
      }

      let data = try Data(contentsOf: cursorURL)
      let recording = try JSONDecoder().decode(CursorRecording.self, from: data)
      var localSpriteMap: [Int: Int] = [:]

      for sprite in recording.sprites {
        let signature = CursorSpriteSignature(sprite: sprite)
        let mergedID: Int
        if let existing = spriteMap[signature] {
          mergedID = existing
        } else {
          mergedID = mergedSprites.count
          spriteMap[signature] = mergedID
          mergedSprites.append(
            CursorSprite(
              id: mergedID,
              width: sprite.width,
              height: sprite.height,
              hotspotX: sprite.hotspotX,
              hotspotY: sprite.hotspotY,
              pixels: sprite.pixels
            )
          )
        }
        localSpriteMap[sprite.id] = mergedID
      }

      for frame in recording.frames {
        let mergedSpriteID = frame.spriteID >= 0 ? (localSpriteMap[frame.spriteID] ?? frame.spriteID) : -1
        mergedFrames.append(
          CursorFrame(
            t: timeOffset + frame.t,
            x: frame.x,
            y: frame.y,
            spriteID: mergedSpriteID
          )
        )
      }

      timeOffset += segment.recordedDuration
    }

    let mergedRecording = CursorRecording(sprites: mergedSprites, frames: mergedFrames)
    let data = try JSONEncoder().encode(mergedRecording)
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    try data.write(to: outputURL)
  }
}

@available(macOS 15.0, *)
@MainActor
final class CaptureBackendScreenCaptureKit: NSObject, CaptureBackend {
  private enum RunPhase: String {
    case idle
    case starting
    case running
    case stopping
  }

  private enum MicrophoneStartMode: Equatable {
    case disabled
    case selectedDevice(String)
    case systemDefault

    init(device: AVCaptureDevice?) {
      guard let device else {
        self = .disabled
        return
      }

      let uniqueID = device.uniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
      self = uniqueID.isEmpty ? .systemDefault : .selectedDevice(uniqueID)
    }

    var captureEnabled: Bool {
      switch self {
      case .disabled:
        return false
      case .selectedDevice, .systemDefault:
        return true
      }
    }

    var selectedDeviceID: String? {
      guard case .selectedDevice(let id) = self else { return nil }
      return id
    }

    var logValue: String {
      switch self {
      case .disabled:
        return "disabled"
      case .selectedDevice(let id):
        return id
      case .systemDefault:
        return "default"
      }
    }
  }

  // MARK: CaptureBackend
  var onStarted: ((URL) -> Void)?
  var onFinished: ((URL?, Error?) -> Void)?
  var onPaused: (() -> Void)?
  var onResumed: (() -> Void)?
  var onWarning: ((String) -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?

  var canPauseResume: Bool { true }
  var supportsLiveOverlayExclusionDuringSeparateCameraCapture: Bool { true }
  var isRecording: Bool { recordingURL != nil && didStart }
  var isPaused: Bool { paused }
  var currentOutputURL: URL? { recordingURL }
  var recordedScreenSegments: [RecordingMetadata.CaptureSegment] {
    segmentedSession?.recordedScreenSegments ?? []
  }

  // MARK: Internals
  private let cursorRecorder = CursorRecorder()
  private var stream: SCStream?
  private var recordingOutput: SCRecordingOutput?
  private var activeStreamConfig: SCStreamConfiguration?

  private var recordingURL: URL?
  private var didStart: Bool = false
  private var paused: Bool = false
  private var stopRequested: Bool = false
  private var runPhase: RunPhase = .idle
  private var segmentedSession: SegmentedRecordingSession?
  private var activeSegmentContext: RecordingSegmentContext?
  private var segmentContextsByOutputID: [ObjectIdentifier: RecordingSegmentContext] = [:]

  // Keep these for CursorRecorder normalization (reuse our existing cropRect logic)
  private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
  private var currentCaptureRect: CGRect?
  private var currentCursorRasterScale: Double = 1.0

  // Track whether recorder app is excluded from capture
  // When excluded, cursor recording is disabled to avoid misleading zoom effects
  private var isRecorderExcluded: Bool = false

  // Queues for sample outputs (even if don’t consume frames)
  private let videoQ = DispatchQueue(label: "SCK.VideoSampleBufferQueue")
  private let audioQ = DispatchQueue(label: "SCK.AudioSampleBufferQueue")
  private let micQ = DispatchQueue(label: "SCK.MicSampleBufferQueue")

  // State for dynamic updates
  private var currentConfig: CaptureStartConfig?
  private var currentOverlayWindowID: CGWindowID?
  private var pendingOverlayWindowID: CGWindowID?
  private var lastAppliedOverlayWindowID: CGWindowID?
  private var windowMoveTimer: Timer?
  private var lastSourceRect: CGRect?
  private var isFlushingOverlayUpdates: Bool = false
  private var streamMutationTail: Task<Void, Never>?
  private var nextStreamMutationSequence: Int = 0
  private var terminalCompletionGuard = TerminalCompletionGuard()
  private var isCursorCaptureActive = false
  private var smoothedMicLevelLinear: Double = 0.0
  private var lastMicLevelEmitAt: CFTimeInterval = 0.0
  private let micLevelEmitInterval: CFTimeInterval = 1.0 / 15.0
  private var pendingRecordingWarningMessage: String?

  func start(config: CaptureStartConfig) {
    terminalCompletionGuard.reset()
    self.currentConfig = config
    self.currentOverlayWindowID = config.cameraOverlayWindowID
    self.pendingOverlayWindowID = config.cameraOverlayWindowID
    self.lastAppliedOverlayWindowID = nil
    self.runPhase = .starting
    Task { await startAsync(config: config) }
  }

  func stop() {
    runPhase = .stopping
    stopWindowMoveTimer()
    Task { await stopAsync() }
  }

  func pause() {
    Task { await pauseAsync() }
  }

  func resume() {
    Task { await resumeAsync() }
  }

  func updateOverlay(windowID: CGWindowID?) {
    currentOverlayWindowID = windowID
    pendingOverlayWindowID = windowID

    guard runPhase == .running, didStart, !stopRequested else {
      NativeLogger.d(
        "SCKBackend", "Deferring overlay update until stream is running",
        context: [
          "windowID": Int(windowID ?? 0),
          "phase": runPhase.rawValue,
        ])
      return
    }

    Task { @MainActor in
      await flushOverlayUpdateIfNeeded()
    }
  }

  private func startWindowMoveTimer() {
    stopWindowMoveTimer()
    guard let target = currentConfig?.target, target.mode == .singleAppWindow,
      let windowID = target.windowID
    else { return }

    windowMoveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      Task { @MainActor in
        await self.checkWindowMove(windowID: windowID)
      }
    }
  }

  private func stopWindowMoveTimer() {
    windowMoveTimer?.invalidate()
    windowMoveTimer = nil
  }

  private func checkWindowMove(windowID: CGWindowID) async {
    guard runPhase == .running else { return }

    let windowIDArray = [windowID] as CFArray
    guard let info = CGWindowListCreateDescriptionFromArray(windowIDArray) as? [[String: Any]],
      let first = info.first,
      let boundsDict = first[kCGWindowBounds as String] as? [String: Any],
      let newFrame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    else { return }

    if newFrame != lastSourceRect {
      do {
        try await performSerializedStreamMutation { sequence in
          guard self.runPhase == .running, let stream = self.stream,
            let config = self.activeStreamConfig
          else { return }

          self.lastSourceRect = newFrame
          config.sourceRect = newFrame

          NativeLogger.d(
            "SCKBackend", "Updating sourceRect",
            context: [
              "sequence": sequence,
              "windowID": Int(windowID),
              "sourceRect": NSStringFromRect(newFrame),
            ])

          try await stream.updateConfiguration(config)

          NativeLogger.i(
            "SCKBackend", "Updated sourceRect",
            context: [
              "sequence": sequence,
              "windowID": Int(windowID),
              "sourceRect": NSStringFromRect(newFrame),
            ])
        }
      } catch {
        NativeLogger.e(
          "SCKBackend", "Failed to update sourceRect",
          context: [
            "windowID": Int(windowID),
            "sourceRect": NSStringFromRect(newFrame),
            "error": "\(error)",
          ])
      }
    }
  }

  // MARK: Start/Stop
  private func startAsync(config: CaptureStartConfig) async {
    do {
      let outURL = try config.makeOutputURL()
      pendingRecordingWarningMessage = nil
      initializeStartAttemptState(config: config, outputURL: outURL)

      NativeLogger.i(
        "SCKBackend", "Start requested",
        context: [
          "mode": "\(config.target.mode)",
          "windowID": config.target.windowID.map { Int($0) } ?? NSNull(),
          "displayID": Int(config.target.displayID),
          "hasCropRect": config.target.cropRect != nil,
          "out": outURL.path,
        ])
      await startCaptureAttempt(
        config: config,
        outputURL: outURL,
        microphoneStartMode: MicrophoneStartMode(device: config.includeAudioDevice)
      )
    } catch {
      NativeLogger.e("SCKBackend", "Start failed", context: ["error": "\(error)"])
      finishWithFailure(error)
    }
  }

  private func startCaptureAttempt(
    config: CaptureStartConfig,
    outputURL: URL,
    microphoneStartMode: MicrophoneStartMode
  ) async {
    do {
      initializeStartAttemptState(config: config, outputURL: outputURL)

      // Resolve shareable content once (windows + displays + running apps)
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)

      // Build the proper filter for the requested target (window vs display)
      let initialOverlayWindowID = currentOverlayWindowID
      let built = try buildContentFilter(
        for: config.target, content: content, excludeRecorderApp: config.excludeRecorderApp,
        cameraOverlayWindowID: initialOverlayWindowID,
        excludeCameraOverlayWindow: config.excludeCameraOverlayWindow
      )
      let filter = built.filter
      let sourceRect = built.sourceRect

      self.lastSourceRect = sourceRect
      self.lastAppliedOverlayWindowID = initialOverlayWindowID

      dbg_pointPixelScale = CGFloat(filter.pointPixelScale)
      dbg_filterContentRect = filter.contentRect
      dbg_sourceRect = sourceRect

      let baseRectPoints = sourceRect ?? filter.contentRect
      let expectedW = (baseRectPoints.width * dbg_pointPixelScale).rounded()
      let expectedH = (baseRectPoints.height * dbg_pointPixelScale).rounded()

      NativeLogger.i(
        "SCKBackend",
        "Geometry intent (filter/source/config)",
        context: [
          "pointPixelScale": dbg_pointPixelScale,
          "filter.contentRect_pts": NSStringFromRect(filter.contentRect),
          "sourceRect_pts": sourceRect.map { NSStringFromRect($0) } ?? "nil",
          "expected_px": "\(Int(expectedW))x\(Int(expectedH))",
        ]
      )

      // Configure stream (stable output size; optional crop via sourceRect)
      let streamConfig = makeStreamConfiguration(
        quality: config.quality,
        filter: filter,
        microphoneStartMode: microphoneStartMode,
        includeSystemAudio: config.includeSystemAudio,
        excludeMicFromSystemAudio: config.excludeMicFromSystemAudio,
        sourceRect: sourceRect,
        frameRate: config.frameRate
      )
      self.activeStreamConfig = streamConfig
      dbg_configuredSizePx = CGSize(width: streamConfig.width, height: streamConfig.height)
      currentCursorRasterScale = computeCursorRasterScale(
        baseRectPoints: baseRectPoints,
        streamConfig: streamConfig
      )
      NativeLogger.d(
        "SCKBackend", "Cursor raster scale computed",
        context: [
          "baseRectPtsW": baseRectPoints.width,
          "baseRectPtsH": baseRectPoints.height,
          "configW": streamConfig.width,
          "configH": streamConfig.height,
          "cursorRasterScale": currentCursorRasterScale,
        ])

      NativeLogger.i(
        "SCKBackend",
        "Stream configured",
        context: [
          "config_px": "\(streamConfig.width)x\(streamConfig.height)",
          "scalesToFit": streamConfig.scalesToFit,
          "captureResolution": "\(streamConfig.captureResolution)",
          "minimumFrameInterval": "\(streamConfig.minimumFrameInterval.seconds)",
          "capturesAudio": streamConfig.capturesAudio,
          "captureMicrophone": streamConfig.captureMicrophone,
          "microphoneCaptureDeviceID": streamConfig.microphoneCaptureDeviceID ?? "default",
        ]
      )

      logExpectedGeometry(
        filter: filter,
        sourceRect: sourceRect,
        streamConfig: streamConfig,
        targetMode: "\(config.target.mode)",
        displayID: config.target.displayID
      )

      NativeLogger.d(
        "SCKBackend", "Stream Config",
        context: [
          "mode": "\(config.target.mode)",
          "displayID": Int(config.target.displayID),
          "hasWindowID": config.target.windowID != nil,
          "hasSourceRect": sourceRect != nil,
          "targetW": streamConfig.width,
          "targetH": streamConfig.height,
          "microphoneMode": microphoneStartMode.logValue,
        ])

      let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
      self.stream = stream

      // Add at least .screen output so stream is “active”
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
      if streamConfig.capturesAudio {
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ)
      }
      if streamConfig.captureMicrophone {
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQ)
      }

      let initialSegment = try makeRecordingSegmentContext()
      try stream.addRecordingOutput(initialSegment.recordingOutput)
      recordingOutput = initialSegment.recordingOutput
      activeSegmentContext = initialSegment

      // Start capture (recording begins as stream runs)
      logDiskSpace("before_start_capture", url: outputURL)
      try await performSerializedStreamMutation { sequence in
        NativeLogger.i(
          "SCKBackend", "Starting stream capture",
          context: [
            "sequence": sequence,
            "phase": self.runPhase.rawValue,
            "microphoneMode": microphoneStartMode.logValue,
          ])

        try await stream.startCapture()

        NativeLogger.i(
          "SCKBackend", "Stream started (await startCapture returned)",
          context: [
            "sequence": sequence,
            "microphoneMode": microphoneStartMode.logValue,
          ])
      }

      // Delegate should fire later; safety net in case it doesn't:
      if !didStart {
        await markRecordingStarted(url: outputURL)
      }
    } catch {
      NativeLogger.e(
        "SCKBackend",
        "Start failed",
        context: [
          "error": "\(error)",
          "microphoneMode": microphoneStartMode.logValue,
        ])

      if Self.shouldRetryStartWithDefaultMicrophone(
        error: error as NSError,
        attemptedSelectedMicrophoneID: microphoneStartMode.selectedDeviceID
      ) {
        pendingRecordingWarningMessage = NativeStringsStore.shared.string(
          for: NativeUIStringKey.recordingSelectedMicFallbackWarning)
        await resetStartAttemptForRetry(config: config, outputURL: outputURL)
        NativeLogger.w(
          "SCKBackend",
          "Retrying recording start with system default microphone",
          context: [
            "previousMicrophoneID": microphoneStartMode.selectedDeviceID ?? "nil",
            "outputURL": outputURL.path,
          ])
        await startCaptureAttempt(
          config: config,
          outputURL: outputURL,
          microphoneStartMode: .systemDefault
        )
        return
      }

      if pendingRecordingWarningMessage != nil {
        let localizedError = NativeStringsStore.shared.string(
          for: NativeUIStringKey.recordingSelectedMicFallbackFailure)
        finishWithFailure(flutterError(NativeErrorCode.recordingError, localizedError))
        return
      }

      finishWithFailure(error)
    }
  }

  private func initializeStartAttemptState(config: CaptureStartConfig, outputURL: URL) {
    didStart = false
    paused = false
    stopRequested = false
    runPhase = .starting
    isCursorCaptureActive = false
    segmentedSession = SegmentedRecordingSession(
      primaryInProgressRawURL: outputURL,
      expectsCursorSidecars: !config.excludeRecorderApp
    )
    activeSegmentContext = nil
    segmentContextsByOutputID = [:]
    smoothedMicLevelLinear = 0.0
    lastMicLevelEmitAt = 0.0

    // Store for cursor recorder normalization
    currentDisplayID = config.target.displayID
    currentCaptureRect = config.target.cropRect
    currentCursorRasterScale = 1.0
    isRecorderExcluded = config.excludeRecorderApp
    recordingURL = outputURL
    activeStreamConfig = nil
    lastSourceRect = nil
    lastAppliedOverlayWindowID = nil
    pendingOverlayWindowID = currentOverlayWindowID
    isFlushingOverlayUpdates = false
    streamMutationTail = nil
    nextStreamMutationSequence = 0
    stopWindowMoveTimer()
    stream = nil
    recordingOutput = nil
  }

  private func resetStartAttemptForRetry(config: CaptureStartConfig, outputURL: URL) async {
    let staleStream = stream
    let segmentContexts = Array(segmentContextsByOutputID.values)

    for context in segmentContexts {
      context.finalizationWaiter.fail(flutterError(NativeErrorCode.recordingError, "Retrying start"))
    }

    if let staleStream {
      do {
        try await staleStream.stopCapture()
      } catch {
        NativeLogger.d(
          "SCKBackend",
          "Ignoring stopCapture failure while resetting retry state",
          context: ["error": "\(error)"]
        )
      }
    }

    cursorRecorder.cancel()
    cleanupStartAttemptArtifacts(segmentContexts: segmentContexts)
    initializeStartAttemptState(config: config, outputURL: outputURL)
  }

  private func cleanupStartAttemptArtifacts(segmentContexts: [RecordingSegmentContext]) {
    let fileManager = FileManager.default
    for context in segmentContexts {
      let artifactURLs = [context.rawURL, context.cursorURL].compactMap { $0 }
      for url in artifactURLs where fileManager.fileExists(atPath: url.path) {
        do {
          try fileManager.removeItem(at: url)
        } catch {
          NativeLogger.w(
            "SCKBackend",
            "Failed to remove stale retry artifact",
            context: [
              "path": url.path,
              "error": "\(error)",
            ])
        }
      }
    }
  }

  private func stopAsync() async {
    guard stream != nil else {
      NativeLogger.w("SCKBackend", "Stop called but stream=nil")
      return
    }

    let outURL = recordingURL

    NativeLogger.i(
      "SCKBackend", "Stop requested",
      context: [
        "out": outURL?.path ?? "nil",
        "paused": paused,
        "hasActiveSegment": activeSegmentContext != nil,
      ])

    // Set flag to distinguish user-initiated stop from errors
    stopRequested = true
    runPhase = .stopping
    smoothedMicLevelLinear = 0.0
    lastMicLevelEmitAt = 0.0

    do {
      if let activeSegmentContext {
        try await finalizeSegment(activeSegmentContext)
      }

      try await performSerializedStreamMutation { sequence in
        guard let stream = self.stream else {
          NativeLogger.w(
            "SCKBackend", "Stop mutation skipped because stream=nil",
            context: ["sequence": sequence]
          )
          return
        }

        NativeLogger.d("SCKBackend", "Stopping stream capture...", context: ["sequence": sequence])
        try await stream.stopCapture()
        self.stream = nil
        NativeLogger.d("SCKBackend", "Stream cleanup complete", context: ["sequence": sequence])
      }

      if let session = segmentedSession {
        let mergedOutputURL = try await mergeSegmentArtifacts(session)
        await waitForFileReadyAndFinish(url: mergedOutputURL)
      } else {
        await waitForFileReadyAndFinish(url: outURL)
      }

    } catch {
      NativeLogger.e("SCKBackend", "Stop failed", context: ["error": "\(error)"])
      finishWithFailure(error)
    }
  }

  private func pauseAsync() async {
    guard runPhase == .running, didStart, !stopRequested else {
      NativeLogger.w(
        "SCKBackend", "Ignoring pause outside running phase",
        context: ["phase": runPhase.rawValue, "didStart": didStart, "stopRequested": stopRequested]
      )
      return
    }
    guard !paused else {
      onPaused?()
      return
    }
    guard let activeSegmentContext else {
      finishWithFailure(flutterError(NativeErrorCode.recordingError, "Missing active recording segment"))
      return
    }

    do {
      try await finalizeSegment(activeSegmentContext)
      paused = true
      onPaused?()
    } catch {
      NativeLogger.e("SCKBackend", "Pause failed", context: ["error": "\(error)"])
      finishWithFailure(error)
    }
  }

  private func resumeAsync() async {
    guard runPhase == .running, didStart, !stopRequested else {
      NativeLogger.w(
        "SCKBackend", "Ignoring resume outside running phase",
        context: ["phase": runPhase.rawValue, "didStart": didStart, "stopRequested": stopRequested]
      )
      return
    }
    guard paused else {
      onResumed?()
      return
    }
    guard let stream else {
      finishWithFailure(flutterError(NativeErrorCode.recordingError, "Missing active stream"))
      return
    }

    do {
      let newSegment = try makeRecordingSegmentContext()
      try await performSerializedStreamMutation { sequence in
        NativeLogger.i(
          "SCKBackend", "Adding recording output for resumed segment",
          context: ["sequence": sequence, "segmentIndex": newSegment.index]
        )
        try stream.addRecordingOutput(newSegment.recordingOutput)
        self.recordingOutput = newSegment.recordingOutput
        self.activeSegmentContext = newSegment
      }
      await startCursorSegmentIfNeeded(for: newSegment)
      paused = false
      onResumed?()
    } catch {
      NativeLogger.e("SCKBackend", "Resume failed", context: ["error": "\(error)"])
      finishWithFailure(error)
    }
  }

  private func makeRecordingSegmentContext() throws -> RecordingSegmentContext {
    guard var session = segmentedSession else {
      throw flutterError(NativeErrorCode.recordingError, "Missing segmented recording session")
    }

    let segment = session.nextSegmentURLs()
    segmentedSession = session

    let configuration = SCRecordingOutputConfiguration()
    configuration.outputURL = segment.rawURL
    configuration.outputFileType = .mov
    configuration.videoCodecType = .hevc

    let recordingOutput = SCRecordingOutput(configuration: configuration, delegate: self)
    let context = RecordingSegmentContext(
      index: segment.index,
      rawURL: segment.rawURL,
      cursorURL: segment.cursorURL,
      recordingOutput: recordingOutput
    )
    segmentContextsByOutputID[ObjectIdentifier(recordingOutput)] = context

    NativeLogger.i(
      "SCKBackend", "Prepared recording segment",
      context: [
        "index": segment.index,
        "rawURL": segment.rawURL.path,
        "cursorURL": segment.cursorURL?.path ?? "nil",
      ]
    )

    return context
  }

  private func finalizeSegment(_ segment: RecordingSegmentContext) async throws {
    let finishedAt = Date()
    try await performSerializedStreamMutation { sequence in
      guard let stream = self.stream else {
        throw flutterError(NativeErrorCode.recordingError, "Missing active stream")
      }

      NativeLogger.i(
        "SCKBackend", "Finalizing recording segment",
        context: ["sequence": sequence, "segmentIndex": segment.index]
      )
      try stream.removeRecordingOutput(segment.recordingOutput)
      self.recordingOutput = nil
      self.activeSegmentContext = nil
    }

    try await segment.finalizationWaiter.wait()
    try await stopCursorSegmentIfNeeded(for: segment)

    let fallbackDuration = max(0, finishedAt.timeIntervalSince(segment.startedAt))
    let duration = recordedDurationSeconds(for: segment.rawURL, fallback: fallbackDuration)
    let startedAt = finishedAt.addingTimeInterval(-duration)
    if var session = segmentedSession {
      session.appendSegment(
        index: segment.index,
        rawURL: segment.rawURL,
        cursorURL: segment.cursorURL,
        recordedDuration: duration,
        startWallClock: startedAt,
        endWallClock: finishedAt
      )
      segmentedSession = session
    }
    segmentContextsByOutputID.removeValue(forKey: ObjectIdentifier(segment.recordingOutput))
  }

  private func startCursorSegmentIfNeeded(for segment: RecordingSegmentContext) async {
    guard !isRecorderExcluded else {
      NativeLogger.i("SCKBackend", "Cursor recording disabled (recorder app excluded from capture)")
      isCursorCaptureActive = false
      return
    }

    cursorRecorder.start(
      displayID: currentDisplayID,
      captureRect: currentCaptureRect,
      cursorRasterScale: currentCursorRasterScale
    )
    isCursorCaptureActive = true

    NativeLogger.d(
      "SCKBackend", "Started cursor segment",
      context: ["segmentIndex": segment.index, "cursorURL": segment.cursorURL?.path ?? "nil"]
    )
  }

  private func stopCursorSegmentIfNeeded(for segment: RecordingSegmentContext) async throws {
    guard isCursorCaptureActive, let cursorURL = segment.cursorURL else {
      isCursorCaptureActive = false
      return
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      isCursorCaptureActive = false
      cursorRecorder.stop(outputURL: cursorURL) {
        continuation.resume(returning: ())
      }
    }
  }

  private func mergeSegmentArtifacts(_ session: SegmentedRecordingSession) async throws -> URL {
    let orderedSegments = session.segmentArtifacts.sorted(by: { $0.index < $1.index })
    NativeLogger.i(
      "SCKBackend", "Merging recording segments",
      context: [
        "count": orderedSegments.count,
        "output": session.primaryInProgressRawURL.path,
      ]
    )

    let mergedURL = try await RecordingSegmentMerger.mergeSegments(
      orderedSegments.map(\.rawURL),
      to: session.primaryInProgressRawURL
    )

    try CursorSegmentMerger.mergeSegments(
      orderedSegments,
      expectsCursorSidecars: session.expectsCursorSidecars,
      outputURL: finalCursorDataURL(for: mergedURL)
    )

    cleanupMergedSegmentArtifacts(orderedSegments, finalURL: mergedURL)
    return mergedURL
  }

  private func cleanupMergedSegmentArtifacts(_ segments: [SegmentedRecordingArtifact], finalURL: URL) {
    let fm = FileManager.default
    for segment in segments {
      if fm.fileExists(atPath: segment.rawURL.path), segment.rawURL != finalURL {
        try? fm.removeItem(at: segment.rawURL)
      }
      if let cursorURL = segment.cursorURL, fm.fileExists(atPath: cursorURL.path) {
        try? fm.removeItem(at: cursorURL)
      }
    }
  }

  /// Waits until the video file is truly playable before calling onFinished
  private func waitForFileReadyAndFinish(url: URL?) async {
    guard let url else {
      NativeLogger.w("SCKBackend", "No URL to finalize")
      finishSuccessfully(url: nil)
      return
    }

    NativeLogger.d("SCKBackend", "Waiting for file readiness", context: ["path": url.path])

    // Give the system a moment to finalize the file before we start checking
    try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms initial delay

    let isReady = await waitUntilAssetPlayable(url: url, timeout: 3.0)

    if isReady {
      NativeLogger.i("SCKBackend", "File is ready and playable", context: ["path": url.path])
      finishSuccessfully(url: url)
    } else {
      NativeLogger.e(
        "SCKBackend", "File failed readiness check after timeout", context: ["path": url.path])

      // Try to get more info about the file
      if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        NativeLogger.e(
          "SCKBackend", "File exists but not playable",
          context: [
            "size": size,
            "path": url.path,
          ])
      }

      finishSuccessfully(url: url)  // Still finish, but log the warning
    }
  }

  /// Checks if the asset is playable by loading its properties asynchronously
  private func waitUntilAssetPlayable(url: URL, timeout: TimeInterval) async -> Bool {
    let startTime = Date()
    let retryInterval: TimeInterval = 0.15  // 150ms
    var attemptCount = 0

    while Date().timeIntervalSince(startTime) < timeout {
      attemptCount += 1

      // Check file exists
      guard FileManager.default.fileExists(atPath: url.path) else {
        NativeLogger.d(
          "SCKBackend", "File readiness check: file does not exist yet",
          context: [
            "attempt": attemptCount,
            "path": url.path,
          ])
        try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
        continue
      }

      // Check file size
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

      if fileSize < 1000 {
        NativeLogger.d(
          "SCKBackend", "File readiness check: file too small",
          context: [
            "attempt": attemptCount,
            "size": fileSize,
          ])
        try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
        continue
      }

      // Check if AVAsset is playable
      let asset = AVURLAsset(url: url)

      do {
        // Load properties asynchronously using modern async API
        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)

        let durationSeconds = CMTimeGetSeconds(duration)
        let hasValidDuration =
          durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite

        NativeLogger.d(
          "SCKBackend", "File readiness check",
          context: [
            "attempt": attemptCount,
            "size": fileSize,
            "isPlayable": isPlayable,
            "duration": durationSeconds,
            "trackCount": tracks.count,
          ])

        if isPlayable && hasValidDuration && !tracks.isEmpty {
          NativeLogger.i(
            "SCKBackend", "Asset is playable and ready",
            context: [
              "attempts": attemptCount,
              "size": fileSize,
              "duration": durationSeconds,
            ])
          return true
        }

      } catch {
        NativeLogger.w(
          "SCKBackend", "Asset loading error",
          context: [
            "attempt": attemptCount,
            "error": "\(error)",
            "errorType": "\(type(of: error))",
            "localizedDescription": error.localizedDescription,
          ])
      }

      try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
    }

    NativeLogger.w(
      "SCKBackend", "Asset readiness timeout",
      context: [
        "attempts": attemptCount,
        "timeout": timeout,
      ])
    return false
  }

  // MARK: Helpers
  private func finishSuccessfully(url: URL?) {
    guard terminalCompletionGuard.beginCompletion() else {
      NativeLogger.w("SCKBackend", "Ignoring duplicate terminal success completion")
      return
    }

    if let url { logFinalVideoInfo(url: url) }
    NativeLogger.i("SCKBackend", "Finished", context: ["url": url?.path ?? "nil"])
    onFinished?(url, nil)
    resetState()
  }

  private func finishWithFailure(_ error: Error) {
    guard terminalCompletionGuard.beginCompletion() else {
      NativeLogger.w(
        "SCKBackend", "Ignoring duplicate terminal failure completion",
        context: ["error": "\(error)"])
      return
    }

    let cursorURL = activeSegmentContext?.cursorURL
    let shouldFlushCursor = isCursorCaptureActive && cursorURL != nil
    for context in segmentContextsByOutputID.values {
      context.finalizationWaiter.fail(error)
    }

    cleanupStreamAfterFailure(discardCursor: !shouldFlushCursor)

    guard shouldFlushCursor, let cursorURL else {
      completeFailure(url: nil, error: error, cursorURL: cursorURL)
      return
    }

    NativeLogger.i(
      "SCKBackend", "Flushing cursor recording after failure",
      context: [
        "cursor": cursorURL.path,
        "url": recordingURL?.path ?? "nil",
      ])

    cursorRecorder.stop(outputURL: cursorURL) { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.completeFailure(url: nil, error: error, cursorURL: cursorURL)
      }
    }
  }

  private func completeFailure(url: URL?, error: Error, cursorURL: URL?) {
    let cursorExists = cursorURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

    NativeLogger.i(
      "SCKBackend", "Failure completion artifact status",
      context: [
        "url": url?.path ?? "nil",
        "cursorPath": cursorURL?.path ?? "nil",
        "cursorExists": cursorExists,
      ])

    resetState()
    onFinished?(url, error)
  }

  private func resetState() {
    didStart = false
    paused = false
    stopRequested = false
    runPhase = .idle
    isCursorCaptureActive = false
    smoothedMicLevelLinear = 0.0
    lastMicLevelEmitAt = 0.0
    recordingURL = nil
    pendingRecordingWarningMessage = nil
    segmentedSession = nil
    activeSegmentContext = nil
    segmentContextsByOutputID = [:]
    currentConfig = nil
    currentOverlayWindowID = nil
    pendingOverlayWindowID = nil
    lastAppliedOverlayWindowID = nil
    currentCaptureRect = nil
    activeStreamConfig = nil
    lastSourceRect = nil
    isFlushingOverlayUpdates = false
    streamMutationTail = nil
    nextStreamMutationSequence = 0
    stopWindowMoveTimer()
    stream = nil
    recordingOutput = nil
  }

  private func cleanupStreamAfterFailure(discardCursor: Bool) {
    if let stream {
      Task {
        try? await stream.stopCapture()
      }
    }
    if discardCursor {
      cursorRecorder.cancel()
    }
    didStart = false
    paused = false
    stopRequested = false
    runPhase = .idle
    isCursorCaptureActive = false
    smoothedMicLevelLinear = 0.0
    lastMicLevelEmitAt = 0.0
    stopWindowMoveTimer()
    segmentedSession = nil
    activeSegmentContext = nil
    segmentContextsByOutputID = [:]
    stream = nil
    recordingOutput = nil
  }

  private func markRecordingStarted(url: URL) async {
    guard !didStart else { return }

    didStart = true
    paused = false
    runPhase = .running

    startWindowMoveTimer()
    await flushOverlayUpdateIfNeeded()

    if let activeSegmentContext {
      await startCursorSegmentIfNeeded(for: activeSegmentContext)
    }

    onStarted?(url)
    if let warning = pendingRecordingWarningMessage {
      pendingRecordingWarningMessage = nil
      onWarning?(warning)
    }
  }

  private func recordedDurationSeconds(for url: URL, fallback: TimeInterval) -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = asset.duration
    guard duration.isNumeric else {
      return fallback
    }

    let seconds = duration.seconds
    guard seconds.isFinite, seconds > 0 else {
      return fallback
    }

    return seconds
  }

  private func flushOverlayUpdateIfNeeded() async {
    guard runPhase == .running, didStart, !stopRequested else { return }
    guard currentConfig != nil else { return }
    guard !isFlushingOverlayUpdates else { return }

    isFlushingOverlayUpdates = true
    defer { isFlushingOverlayUpdates = false }

    while runPhase == .running && didStart && !stopRequested {
      let requestedWindowID = pendingOverlayWindowID
      pendingOverlayWindowID = nil

      if requestedWindowID == lastAppliedOverlayWindowID {
        if pendingOverlayWindowID == nil {
          return
        }
        continue
      }

      do {
        try await performSerializedStreamMutation { sequence in
          guard self.runPhase == .running, self.didStart, !self.stopRequested,
            let stream = self.stream, let config = self.currentConfig
          else { return }

          NativeLogger.d(
            "SCKBackend", "Applying overlay filter",
            context: [
              "sequence": sequence,
              "windowID": Int(requestedWindowID ?? 0),
            ])

          let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
          let built = try self.buildContentFilter(
            for: config.target,
            content: content,
            excludeRecorderApp: config.excludeRecorderApp,
            cameraOverlayWindowID: requestedWindowID,
            excludeCameraOverlayWindow: config.excludeCameraOverlayWindow
          )

          try await stream.updateContentFilter(built.filter)
          self.lastAppliedOverlayWindowID = requestedWindowID

          NativeLogger.i(
            "SCKBackend", "Overlay updated mid-recording",
            context: [
              "sequence": sequence,
              "windowID": Int(requestedWindowID ?? 0),
            ])
        }
      } catch {
        NativeLogger.e(
          "SCKBackend", "Failed to update overlay",
          context: [
            "windowID": Int(requestedWindowID ?? 0),
            "error": "\(error)",
          ])
        return
      }

      if pendingOverlayWindowID == nil || pendingOverlayWindowID == lastAppliedOverlayWindowID {
        return
      }
    }
  }

  private func performSerializedStreamMutation<T>(
    _ action: @escaping @MainActor (_ sequence: Int) async throws -> T
  ) async throws -> T {
    nextStreamMutationSequence += 1
    let sequence = nextStreamMutationSequence
    let previous = streamMutationTail

    let task = Task<T, Error> { @MainActor in
      if let previous {
        _ = await previous.result
      }
      return try await action(sequence)
    }

    streamMutationTail = Task { @MainActor in
      _ = try? await task.value
    }

    return try await task.value
  }

  private func logDiskSpace(_ label: String, url: URL?) {
    guard let dir = url?.deletingLastPathComponent() else { return }

    do {
      let values = try dir.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      NativeLogger.i(
        "SCKBackend", "Disk space",
        context: [
          "label": label,
          "path": dir.path,
          "important": values.volumeAvailableCapacityForImportantUsage ?? -1,
          "available": values.volumeAvailableCapacity ?? -1,
        ])
    } catch {
      NativeLogger.w(
        "SCKBackend", "Failed to read disk space",
        context: [
          "label": label,
          "path": dir.path,
          "error": "\(error)",
        ])
    }
  }

  private func resolveSCWindow(windowID: CGWindowID, in content: SCShareableContent) throws
    -> SCWindow
  {
    if let win = content.windows.first(where: { $0.windowID == windowID }) {
      NativeLogger.d(
        "SCKBackend", "Resolved SCWindow",
        context: [
          "windowID": Int(windowID),
          "title": win.title ?? "",
          "frame": NSStringFromRect(win.frame),
          "owner": win.owningApplication?.bundleIdentifier ?? "nil",
        ])
      return win
    }

    NativeLogger.e("SCKBackend", "SCWindow not found", context: ["windowID": Int(windowID)])
    throw flutterError(NativeErrorCode.windowNotAvailable, "Window not found in SCShareableContent")
  }

  private func resolveSCDisplay(displayID: CGDirectDisplayID, in content: SCShareableContent) throws
    -> SCDisplay
  {
    if let d = content.displays.first(where: { $0.displayID == displayID }) {
      NativeLogger.d("SCKBackend", "Resolved SCDisplay", context: ["displayID": Int(displayID)])
      return d
    }

    NativeLogger.e("SCKBackend", "SCDisplay not found", context: ["displayID": Int(displayID)])
    throw flutterError(NativeErrorCode.targetError, "Display not found in SCShareableContent")
  }

  private func selfAppWindows(toExclude overlayID: CGWindowID?, from content: SCShareableContent)
    -> [SCWindow]
  {
    guard let bid = Bundle.main.bundleIdentifier else { return [] }
    return content.windows.filter {
      $0.owningApplication?.bundleIdentifier == bid && $0.windowID != (overlayID ?? 0)
    }
  }

  private func excludedWindows(
    from content: SCShareableContent,
    overlayWindowID: CGWindowID?,
    excludeRecorderApp: Bool,
    excludeCameraOverlayWindow: Bool
  ) -> [SCWindow] {
    let windowRecords = content.windows.map {
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(
        windowID: $0.windowID,
        bundleIdentifier: $0.owningApplication?.bundleIdentifier
      )
    }
    let excludedWindowIDs = ScreenCaptureKitOverlayFilterPolicy.excludedWindowIDs(
      windows: windowRecords,
      selfBundleIdentifier: Bundle.main.bundleIdentifier,
      overlayWindowID: overlayWindowID,
      excludeRecorderApp: excludeRecorderApp,
      excludeCameraOverlayWindow: excludeCameraOverlayWindow
    )
    let excludedWindowIDSet = Set(excludedWindowIDs)
    return content.windows.filter { excludedWindowIDSet.contains($0.windowID) }
  }

  private func buildContentFilter(
    for target: CaptureTarget,
    content: SCShareableContent,
    excludeRecorderApp: Bool,
    cameraOverlayWindowID: CGWindowID?,
    excludeCameraOverlayWindow: Bool
  ) throws -> (filter: SCContentFilter, sourceRect: CGRect?, sourceSize: CGSize) {

    switch target.mode {
    case .singleAppWindow:
      guard let windowID = target.windowID else {
        throw flutterError(NativeErrorCode.windowNotAvailable, "Missing windowID")
      }
      let scWindow = try resolveSCWindow(windowID: windowID, in: content)

      if let overlayID = cameraOverlayWindowID, !excludeCameraOverlayWindow {
        // Option 1: Display-based capture + crop to target app window.
        // We include both the target app and our own app, but filter out other recorder windows.
        let display = try resolveSCDisplay(displayID: target.displayID, in: content)

        let targetApp = scWindow.owningApplication
        let selfApp = content.applications.first {
          $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let appsToInclude = [targetApp, selfApp].compactMap { $0 }
        let winsToExclude = selfAppWindows(toExclude: overlayID, from: content)

        NativeLogger.i(
          "SCKBackend", "Building hybrid filter for Window + Overlay",
          context: [
            "targetApp": targetApp?.bundleIdentifier ?? "nil", "excepting": winsToExclude.count,
          ])

        let filter = SCContentFilter(
          display: display, including: appsToInclude, exceptingWindows: winsToExclude)

        return (filter, scWindow.frame, scWindow.frame.size)
      } else {
        // Original behavior: True window capture (captures only the target window hierarchy)
        return (SCContentFilter(desktopIndependentWindow: scWindow), nil, scWindow.frame.size)
      }

    case .areaRecording:
      /// OLD WAY
      /*
            let display = try resolveSCDisplay(displayID: target.displayID, in: content)
        // Conditionally exclude recorder app based on preference
        let appsToExclude = excludeRecorderApp ? excludedApps(from: content) : []
        // If camera overlay is active, except it from exclusion
        var exceptions: [SCWindow] = []
        if let overlayID = cameraOverlayWindowID,
          let win = content.windows.first(where: { $0.windowID == overlayID })
        {
          exceptions.append(win)
        }
      
        let filter = SCContentFilter(
          display: display,
          excludingApplications: appsToExclude,
          exceptingWindows: exceptions
        )
        // For area recording, sourceSize is the cropRect size if available, else display size
        let size = target.cropRect?.size ?? CGSize(width: display.width, height: display.height)
        return (filter, target.cropRect, size)
      */
      let display = try resolveSCDisplay(displayID: target.displayID, in: content)
      let winsToExclude = excludedWindows(
        from: content,
        overlayWindowID: cameraOverlayWindowID,
        excludeRecorderApp: excludeRecorderApp,
        excludeCameraOverlayWindow: excludeCameraOverlayWindow
      )
      let filter = SCContentFilter(display: display, excludingWindows: winsToExclude)
      // For area recording, sourceSize is the cropRect size if available, else display size
      let sourceSize = target.cropRect?.size ?? CGSize(width: display.width, height: display.height)
      return (filter, target.cropRect, sourceSize)

    case .explicitID, .appWindow, .mouseAtStart, .followMouse:
      /// OLD WAY
      /*
      let display = try resolveSCDisplay(displayID: target.displayID, in: content)
      // Conditionally exclude recorder app based on preference
      let appsToExclude = excludeRecorderApp ? excludedApps(from: content) : []
      // If camera overlay is active, except it from exclusion
      var exceptions: [SCWindow] = []
      if let overlayID = cameraOverlayWindowID,
        let win = content.windows.first(where: { $0.windowID == overlayID })
      {
        exceptions.append(win)
      }
      
      let filter = SCContentFilter(
        display: display,
        excludingApplications: appsToExclude,
        exceptingWindows: exceptions
      )
      return (filter, nil, CGSize(width: display.width, height: display.height))
      */
      let display = try resolveSCDisplay(displayID: target.displayID, in: content)
      let winsToExclude = excludedWindows(
        from: content,
        overlayWindowID: cameraOverlayWindowID,
        excludeRecorderApp: excludeRecorderApp,
        excludeCameraOverlayWindow: excludeCameraOverlayWindow
      )
      let filter = SCContentFilter(display: display, excludingWindows: winsToExclude)

      let sourceSize = target.cropRect?.size ?? CGSize(width: display.width, height: display.height)
      return (filter, nil, sourceSize)
    }
  }

  private func makeStreamConfiguration(
    quality: RecordingQuality,
    filter: SCContentFilter,
    microphoneStartMode: MicrophoneStartMode,
    includeSystemAudio: Bool,
    excludeMicFromSystemAudio: Bool,
    sourceRect: CGRect?,
    frameRate: Int
  ) -> SCStreamConfiguration {

    let c = SCStreamConfiguration()
    c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    c.showsCursor = false

    // Strongly recommended for sharpness / full-res capture
    c.captureResolution = .best  //SCCaptureResolutionBest  // or .best in Swift, depending on SDK
    c.preservesAspectRatio = true

    // Rect in points (DIPs)
    let baseRectPoints = sourceRect ?? filter.contentRect
    let scale = filter.pointPixelScale

    // Size in pixels
    let pixelW = Int((baseRectPoints.width * CGFloat(scale)).rounded())
    let pixelH = Int((baseRectPoints.height * CGFloat(scale)).rounded())

    if quality == .native {
      c.width = pixelW
      c.height = pixelH
      c.scalesToFit = false
    } else {
      // Preset target sizes are specified in pixels.
      let target = quality.targetSize
      c.width = min(pixelW, Int(target.width))
      c.height = min(pixelH, Int(target.height))
      c.scalesToFit = true
    }

    if let sourceRect {
      // IMPORTANT: this stays in points (DIPs)
      c.sourceRect = sourceRect
    }

    c.capturesAudio = includeSystemAudio
    c.captureMicrophone = microphoneStartMode.captureEnabled
    if let micId = microphoneStartMode.selectedDeviceID {
      c.microphoneCaptureDeviceID = micId
    } else {
      c.microphoneCaptureDeviceID = nil
    }

    // When both system audio and a mic are active, optionally exclude Clingfy's own process audio
    // from the system capture to prevent feedback / double-mic artefacts (requires macOS 13+).
    if includeSystemAudio && excludeMicFromSystemAudio {
      c.excludesCurrentProcessAudio = true
    }

    return c
  }

  static func shouldRetryStartWithDefaultMicrophone(
    error: NSError,
    attemptedSelectedMicrophoneID: String?
  ) -> Bool {
    guard let attemptedSelectedMicrophoneID,
      !attemptedSelectedMicrophoneID.isEmpty,
      error.domain == SCStreamErrorDomain
    else {
      return false
    }

    return error.code == -3812 || error.code == -3820
  }

  private func computeCursorRasterScale(
    baseRectPoints: CGRect,
    streamConfig: SCStreamConfiguration
  ) -> Double {
    let baseW = max(Double(baseRectPoints.width), 1.0)
    let baseH = max(Double(baseRectPoints.height), 1.0)
    let scaleX = Double(streamConfig.width) / baseW
    let scaleY = Double(streamConfig.height) / baseH
    return clampedCursorRasterScale(min(scaleX, scaleY))
  }

  private func clampedCursorRasterScale(_ value: Double) -> Double {
    min(max(value, 0.1), 8.0)
  }

  private func logFinalVideoInfo(url: URL) {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
      NativeLogger.w("SCKBackend", "No video track found", context: ["url": url.path])
      return
    }

    let t = track.preferredTransform
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(t)
    let w = abs(rect.width)
    let h = abs(rect.height)

    NativeLogger.i(
      "SCKBackend", "Final video track info",
      context: [
        "url": url.path,
        "w": w,
        "h": h,
        "nominalFps": track.nominalFrameRate,
        "estimatedDataRate_bps": track.estimatedDataRate,
      ])
    let baseRectPoints = dbg_sourceRect ?? dbg_filterContentRect
    let expectedW = (baseRectPoints.width * dbg_pointPixelScale).rounded()
    let expectedH = (baseRectPoints.height * dbg_pointPixelScale).rounded()

    // Rough bitrate from file size + duration
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let bytes = (attrs?[.size] as? NSNumber)?.doubleValue ?? 0
    let seconds = max(asset.duration.seconds, 0.001)
    let bpsFromFile = (bytes * 8.0) / seconds

    NativeLogger.i(
      "SCKBackend",
      "Geometry + bitrate (recorded vs expected)",
      context: [
        "recorded": "\(Int(w))x\(Int(h))",
        "expected": "\(Int(expectedW))x\(Int(expectedH))",
        "configured": "\(Int(dbg_configuredSizePx.width))x\(Int(dbg_configuredSizePx.height))",
        "estimatedDataRate_track_bps": track.estimatedDataRate,
        "bitrate_from_file_bps": bpsFromFile,
        "file_bytes": bytes,
        "duration_s": seconds,
      ]
    )

    compareRecordedToExpected(recordedW: w, recordedH: h)

  }
  // MARK: Geometry debug
  private var debug_baseRectPoints: CGRect?
  private var debug_pointPixelScale: CGFloat?
  private var debug_expectedPixels: CGSize?
  private var debug_configuredPixels: CGSize?
  // Capture intent vs reality
  private var dbg_pointPixelScale: CGFloat = 1.0
  private var dbg_filterContentRect: CGRect = .zero
  private var dbg_sourceRect: CGRect?
  private var dbg_configuredSizePx: CGSize = .zero

  private func logExpectedGeometry(
    filter: SCContentFilter,
    sourceRect: CGRect?,
    streamConfig: SCStreamConfiguration,
    targetMode: String,
    displayID: CGDirectDisplayID
  ) {
    let baseRectPoints = sourceRect ?? filter.contentRect
    let scale = CGFloat(filter.pointPixelScale)

    let expectedW = (baseRectPoints.width * scale)
    let expectedH = (baseRectPoints.height * scale)

    debug_baseRectPoints = baseRectPoints
    debug_pointPixelScale = scale
    debug_expectedPixels = CGSize(width: expectedW, height: expectedH)
    debug_configuredPixels = CGSize(
      width: CGFloat(streamConfig.width), height: CGFloat(streamConfig.height))

    NativeLogger.i(
      "SCKBackend", "Geometry (expected vs configured)",
      context: [
        "mode": targetMode,
        "displayID": Int(displayID),

        // Raw inputs (points)
        "filter.contentRect_points": NSStringFromRect(filter.contentRect),
        "sourceRect_points": sourceRect.map { NSStringFromRect($0) } ?? "nil",
        "baseRect_points": NSStringFromRect(baseRectPoints),
        "pointPixelScale": Double(scale),

        // Expected (pixels)
        "expectedPxW": Double(expectedW),
        "expectedPxH": Double(expectedH),

        // Configured stream output (pixels)
        "configuredPxW": streamConfig.width,
        "configuredPxH": streamConfig.height,
        "scalesToFit": streamConfig.scalesToFit,
        "captureResolution": "\(streamConfig.captureResolution)",
      ])
  }

  private func compareRecordedToExpected(recordedW: CGFloat, recordedH: CGFloat) {
    guard
      let expected = debug_expectedPixels,
      expected.width > 0, expected.height > 0
    else {
      NativeLogger.w("SCKBackend", "Geometry compare skipped (no expectedPixels)")
      return
    }

    // Orientation can swap w/h depending on transform; compare both ways.
    let directRatioW = recordedW / expected.width
    let directRatioH = recordedH / expected.height
    let swappedRatioW = recordedW / expected.height
    let swappedRatioH = recordedH / expected.width

    // Choose "best" match by smallest total error from 1.0
    let directErr = abs(1.0 - directRatioW) + abs(1.0 - directRatioH)
    let swappedErr = abs(1.0 - swappedRatioW) + abs(1.0 - swappedRatioH)

    let bestIsDirect = directErr <= swappedErr
    let bestRW = bestIsDirect ? directRatioW : swappedRatioW
    let bestRH = bestIsDirect ? directRatioH : swappedRatioH

    let configured = debug_configuredPixels
    let confRatioW = configured.map { recordedW / max($0.width, 1) } ?? -1
    let confRatioH = configured.map { recordedH / max($0.height, 1) } ?? -1

    NativeLogger.i(
      "SCKBackend", "Geometry compare (recorded vs expected)",
      context: [
        "recordedW": Double(recordedW),
        "recordedH": Double(recordedH),

        "expectedW": Double(expected.width),
        "expectedH": Double(expected.height),

        // Best-match ratio: ~0.5 means “half-res”, ~1.0 means “correct”
        "bestMatch": bestIsDirect ? "direct" : "swapped",
        "ratioRecordedToExpectedW": Double(bestRW),
        "ratioRecordedToExpectedH": Double(bestRH),

        // Also compare to configured stream size
        "ratioRecordedToConfiguredW": Double(confRatioW),
        "ratioRecordedToConfiguredH": Double(confRatioH),
      ])
  }

  private func excludedApps(from content: SCShareableContent) -> [SCRunningApplication] {
    guard let bid = Bundle.main.bundleIdentifier else { return [] }
    return content.applications.filter { $0.bundleIdentifier == bid }
  }

  private func handleMicrophoneLevel(_ sample: MicrophoneLevelSample) {
    let alpha = sample.linear >= smoothedMicLevelLinear ? 0.35 : 0.18
    smoothedMicLevelLinear = smoothedMicLevelLinear * (1.0 - alpha) + sample.linear * alpha
    let now = CACurrentMediaTime()
    if now - lastMicLevelEmitAt < micLevelEmitInterval {
      return
    }
    lastMicLevelEmitAt = now
    let smoothed = MicrophoneLevelSample(
      linear: smoothedMicLevelLinear,
      dbfs: AudioLevelEstimator.dbfs(for: smoothedMicLevelLinear)
    )
    onMicrophoneLevel?(smoothed)
  }
}

// MARK: - SCStreamDelegate
@available(macOS 15.0, *)
extension CaptureBackendScreenCaptureKit: SCStreamDelegate {
  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    Task { @MainActor in
      guard stream === self.stream else {
        NativeLogger.d(
          "SCKBackend", "Ignoring stale stream didStopWithError callback",
          context: ["error": "\(error)"]
        )
        return
      }

      let nsError = error as NSError
      let errorCode = nsError.code
      let errorDomain = nsError.domain

      self.logDiskSpace("stream_did_stop_with_error", url: self.recordingURL)
      NativeLogger.d(
        "SCKBackend", "Stream didStopWithError",
        context: [
          "error": "\(error)",
          "code": errorCode,
          "domain": errorDomain,
          "stopRequested": self.stopRequested,
          "phase": self.runPhase.rawValue,
        ])

      // Filter errors that occur during user-initiated stop
      if self.stopRequested {
        // According to Apple docs, these errors are expected during stop:
        // - userStopped (-3808): User intentionally stopped the stream
        // - failedApplicationConnectionInterrupted (-3803): App connection lost during teardown

        // SCStreamErrorCode values (from ScreenCaptureKit framework):
        // userStopped = -3808
        // failedApplicationConnectionInterrupted = -3803

        let ignorableCodes: [Int] = [-3808, -3803]

        if ignorableCodes.contains(errorCode) {
          NativeLogger.i(
            "SCKBackend", "Ignoring expected stop-time error",
            context: [
              "code": errorCode,
              "description": "\(error)",
            ])
          // Don't call onFinished - the normal stop flow will handle it
          return
        }

        // For other errors during stop, log but still ignore (we're stopping anyway)
        NativeLogger.w(
          "SCKBackend", "Unexpected error during stop, ignoring",
          context: [
            "code": errorCode,
            "error": "\(error)",
          ])
        return
      }

      // Real error during active recording - propagate it
      NativeLogger.e(
        "SCKBackend", "Stream stopped with error during active recording",
        context: [
          "error": "\(error)",
          "code": errorCode,
        ])
      self.finishWithFailure(error)
    }
  }
}

// MARK: - SCStreamOutput (we intentionally ignore frames)
@available(macOS 15.0, *)
extension CaptureBackendScreenCaptureKit: SCStreamOutput {
  nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    // SCRecordingOutput writes the file. We only inspect microphone samples for live level telemetry.
    guard type == .microphone else { return }
    guard let estimate = AudioLevelEstimator.estimatePeak(sampleBuffer: sampleBuffer) else { return }
    let sample = MicrophoneLevelSample(linear: estimate.linear, dbfs: estimate.dbfs)
    Task { @MainActor in
      guard stream === self.stream else { return }
      self.handleMicrophoneLevel(sample)
    }
  }
}

// MARK: - SCRecordingOutputDelegate
@available(macOS 15.0, *)
extension CaptureBackendScreenCaptureKit: SCRecordingOutputDelegate {
  nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor in
      let outputID = ObjectIdentifier(recordingOutput)
      guard let context = self.segmentContextsByOutputID[outputID] else {
        NativeLogger.d("SCKBackend", "Ignoring stale recording start callback")
        return
      }
      NativeLogger.i(
        "SCKBackend", "Recording segment started",
        context: ["segmentIndex": context.index, "rawURL": context.rawURL.path]
      )
      guard let url = self.recordingURL else { return }
      await self.markRecordingStarted(url: url)
    }
  }

  nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor in
      let outputID = ObjectIdentifier(recordingOutput)
      guard let context = self.segmentContextsByOutputID[outputID] else {
        NativeLogger.d("SCKBackend", "Ignoring stale recording finish callback")
        return
      }
      NativeLogger.i(
        "SCKBackend", "Recording segment finished",
        context: ["segmentIndex": context.index, "rawURL": context.rawURL.path]
      )
      context.finalizationWaiter.succeed()
    }
  }

  nonisolated func recordingOutput(
    _ recordingOutput: SCRecordingOutput, didFailWithError error: any Error
  ) {
    Task { @MainActor in
      let outputID = ObjectIdentifier(recordingOutput)
      guard let context = self.segmentContextsByOutputID[outputID] else {
        NativeLogger.d(
          "SCKBackend", "Ignoring stale recording failure callback",
          context: ["error": "\(error)"]
        )
        return
      }
      context.finalizationWaiter.fail(error)
      self.logDiskSpace("recording_output_did_fail", url: self.recordingURL)
      NativeLogger.e(
        "SCKBackend", "Recording failed",
        context: [
          "error": "\(error)",
          "phase": self.runPhase.rawValue,
        ])
      self.finishWithFailure(error)
    }
  }
}
