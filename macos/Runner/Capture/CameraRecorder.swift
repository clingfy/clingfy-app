import AVFoundation
import Foundation

struct CameraRecordingMetadata: Codable, Equatable {
  struct Dimensions: Codable, Equatable {
    let width: Int
    let height: Int
  }

  struct Segment: Codable, Equatable {
    let index: Int
    let relativePath: String
    let startWallClock: String
    let endWallClock: String
  }

  let version: Int
  let recordingId: String
  let rawRelativePath: String
  let metadataRelativePath: String
  let deviceId: String?
  let mirroredRaw: Bool
  let nominalFrameRate: Double?
  let dimensions: Dimensions?
  let startedAt: String
  var endedAt: String?
  var segments: [Segment]

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    try data.write(to: url)
  }
}

struct CameraRecordingSession {
  let recordingId: String
  let outputURL: URL
  let metadataURL: URL
  let rawRelativePath: String
  let metadataRelativePath: String
  let segmentDirectoryURL: URL
  let deviceId: String?
  let mirroredRaw: Bool
  let nominalFrameRate: Double?
  let dimensions: CameraRecordingMetadata.Dimensions?
  let startedAt: Date
  var segments: [CameraRecordingMetadata.Segment] = []

  init(
    outputURL: URL,
    metadataURL: URL,
    rawRelativePath: String? = nil,
    metadataRelativePath: String? = nil,
    segmentDirectoryURL: URL,
    deviceId: String?,
    mirroredRaw: Bool,
    nominalFrameRate: Double?,
    dimensions: CameraRecordingMetadata.Dimensions?,
    startedAt: Date = Date(),
    recordingId: String = UUID().uuidString
  ) {
    self.recordingId = recordingId
    self.outputURL = outputURL
    self.metadataURL = metadataURL
    self.rawRelativePath = rawRelativePath ?? outputURL.lastPathComponent
    self.metadataRelativePath = metadataRelativePath ?? metadataURL.lastPathComponent
    self.segmentDirectoryURL = segmentDirectoryURL
    self.deviceId = deviceId
    self.mirroredRaw = mirroredRaw
    self.nominalFrameRate = nominalFrameRate
    self.dimensions = dimensions
    self.startedAt = startedAt
  }

  func stubMetadata() -> CameraRecordingMetadata {
    CameraRecordingMetadata(
      version: 1,
      recordingId: recordingId,
      rawRelativePath: rawRelativePath,
      metadataRelativePath: metadataRelativePath,
      deviceId: deviceId,
      mirroredRaw: mirroredRaw,
      nominalFrameRate: nominalFrameRate,
      dimensions: dimensions,
      startedAt: CameraRecorder.iso8601String(from: startedAt),
      endedAt: nil,
      segments: segments
    )
  }

  func metadata(endedAt: Date) -> CameraRecordingMetadata {
    var metadata = stubMetadata()
    metadata.endedAt = CameraRecorder.iso8601String(from: endedAt)
    metadata.segments = segments
    return metadata
  }
}

struct CameraRecordingResult {
  let rawURL: URL
  let metadataURL: URL
  let metadata: CameraRecordingMetadata
}

private struct ActiveCameraSegment {
  let index: Int
  let url: URL
  let startedAt: Date
}

private enum CameraMergeUtility {
  static func mergeSegments(
    _ segmentURLs: [URL],
    to outputURL: URL,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard !segmentURLs.isEmpty else {
      completion(.failure(flutterError(NativeErrorCode.videoFileMissing, "No camera segments to merge")))
      return
    }

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
      try? fileManager.removeItem(at: outputURL)
    }

    if segmentURLs.count == 1 {
      do {
        try fileManager.moveItem(at: segmentURLs[0], to: outputURL)
        completion(.success(outputURL))
      } catch {
        completion(.failure(error))
      }
      return
    }

    let composition = AVMutableComposition()
    var timeline = CMTime.zero

    do {
      guard
        let videoTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        throw flutterError(NativeErrorCode.recordingError, "Unable to create merged camera video track")
      }

      var audioTrack: AVMutableCompositionTrack?

      for segmentURL in segmentURLs {
        let asset = AVURLAsset(url: segmentURL)
        guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first else {
          throw flutterError(NativeErrorCode.videoFileMissing, "Missing camera segment video track")
        }
        let duration = asset.duration
        try videoTrack.insertTimeRange(
          CMTimeRange(start: .zero, duration: duration),
          of: sourceVideoTrack,
          at: timeline
        )
        videoTrack.preferredTransform = sourceVideoTrack.preferredTransform

        if let sourceAudioTrack = asset.tracks(withMediaType: .audio).first {
          if audioTrack == nil {
            audioTrack = composition.addMutableTrack(
              withMediaType: .audio,
              preferredTrackID: kCMPersistentTrackID_Invalid
            )
          }
          try audioTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceAudioTrack,
            at: timeline
          )
        }

        timeline = CMTimeAdd(timeline, duration)
      }

      guard
        let exportSession = AVAssetExportSession(
          asset: composition,
          presetName: AVAssetExportPresetPassthrough
        )
      else {
        throw flutterError(NativeErrorCode.recordingError, "Unable to create camera export session")
      }

      exportSession.outputURL = outputURL
      exportSession.outputFileType = .mov
      exportSession.shouldOptimizeForNetworkUse = false
      exportSession.exportAsynchronously {
        DispatchQueue.main.async {
          switch exportSession.status {
          case .completed:
            completion(.success(outputURL))
          case .failed:
            completion(
              .failure(
                exportSession.error
                  ?? flutterError(NativeErrorCode.recordingError, "Camera segment merge failed")
              )
            )
          case .cancelled:
            completion(.failure(flutterError(NativeErrorCode.recordingError, "Camera segment merge cancelled")))
          default:
            completion(.failure(flutterError(NativeErrorCode.recordingError, "Camera segment merge incomplete")))
          }
        }
      }
    } catch {
      completion(.failure(error))
    }
  }
}

final class CameraRecorder: NSObject {
  private let coordinator: CameraCaptureCoordinator
  private let fileManager: FileManager

  private var recordingSession: CameraRecordingSession?
  private var activeSegment: ActiveCameraSegment?
  private var pendingStartCompletion: ((Result<Void, Error>) -> Void)?
  private var pendingPauseCompletion: ((Result<Void, Error>) -> Void)?
  private var pendingStopCompletion: ((Result<CameraRecordingResult, Error>) -> Void)?

  init(
    coordinator: CameraCaptureCoordinator,
    fileManager: FileManager = .default
  ) {
    self.coordinator = coordinator
    self.fileManager = fileManager
    super.init()
  }

  func begin(
    session: CameraRecordingSession,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard recordingSession == nil else {
      completion(.failure(flutterError(NativeErrorCode.alreadyRecording, "Camera recorder already active")))
      return
    }

    do {
      try fileManager.createDirectory(
        at: session.segmentDirectoryURL,
        withIntermediateDirectories: true
      )
      try coordinator.acquireRecording(deviceID: session.deviceId)
      coordinator.setMirrored(session.mirroredRaw)
      recordingSession = session
      startNextSegment(completion: completion)
    } catch {
      completion(.failure(error))
    }
  }

  func pause(completion: @escaping (Result<Void, Error>) -> Void) {
    guard recordingSession != nil else {
      completion(.success(()))
      return
    }

    guard coordinator.recordingOutput.isRecording, activeSegment != nil else {
      completion(.success(()))
      return
    }

    pendingPauseCompletion = completion
    coordinator.recordingOutput.stopRecording()
  }

  func resume(completion: @escaping (Result<Void, Error>) -> Void) {
    guard recordingSession != nil else {
      completion(.failure(flutterError(NativeErrorCode.notRecording, "Camera recorder is not active")))
      return
    }

    guard activeSegment == nil, !coordinator.recordingOutput.isRecording else {
      completion(.success(()))
      return
    }

    startNextSegment(completion: completion)
  }

  func stop(completion: @escaping (Result<CameraRecordingResult, Error>) -> Void) {
    guard recordingSession != nil else {
      completion(.failure(flutterError(NativeErrorCode.notRecording, "Camera recorder is not active")))
      return
    }

    if coordinator.recordingOutput.isRecording, activeSegment != nil {
      pendingStopCompletion = completion
      coordinator.recordingOutput.stopRecording()
      return
    }

    finalizeStoppedRecording(completion: completion)
  }

  private func startNextSegment(completion: @escaping (Result<Void, Error>) -> Void) {
    guard let session = recordingSession else {
      completion(.failure(flutterError(NativeErrorCode.notRecording, "Camera recorder is not active")))
      return
    }

    let nextIndex = session.segments.count
    let segmentURL = session.segmentDirectoryURL.appendingPathComponent(
      String(format: "segment_%03d.mov", nextIndex),
      isDirectory: false
    )
    if fileManager.fileExists(atPath: segmentURL.path) {
      try? fileManager.removeItem(at: segmentURL)
    }

    activeSegment = ActiveCameraSegment(index: nextIndex, url: segmentURL, startedAt: Date())
    pendingStartCompletion = completion

    NativeLogger.i(
      "CameraRecorder",
      "Starting camera segment",
      context: ["index": nextIndex, "path": segmentURL.path]
    )

    coordinator.recordingOutput.startRecording(to: segmentURL, recordingDelegate: self)
  }

  private func finalizeStoppedRecording(
    completion: @escaping (Result<CameraRecordingResult, Error>) -> Void
  ) {
    guard let session = recordingSession else {
      completion(.failure(flutterError(NativeErrorCode.notRecording, "Camera recorder is not active")))
      return
    }

    let segmentURLs = session.segments.map {
      session.segmentDirectoryURL.appendingPathComponent($0.relativePath, isDirectory: false)
    }

    NativeLogger.i(
      "CameraRecorder",
      "Finalizing camera recording",
      context: ["segments": segmentURLs.count, "output": session.outputURL.path]
    )

    CameraMergeUtility.mergeSegments(segmentURLs, to: session.outputURL) { [weak self] result in
      guard let self else { return }

      switch result {
      case .failure(let error):
        self.finishWithFailure(error)
        completion(.failure(error))
      case .success(let mergedURL):
        let metadata = session.metadata(endedAt: Date())
        do {
          try metadata.write(to: session.metadataURL)
          self.cleanupMergedSegments(for: session, finalURL: mergedURL)
          self.finishSuccessfully()
          completion(.success(CameraRecordingResult(rawURL: mergedURL, metadataURL: session.metadataURL, metadata: metadata)))
        } catch {
          self.finishWithFailure(error)
          completion(.failure(error))
        }
      }
    }
  }

  private func cleanupMergedSegments(for session: CameraRecordingSession, finalURL: URL) {
    for segment in session.segments {
      let url = session.segmentDirectoryURL.appendingPathComponent(segment.relativePath, isDirectory: false)
      if url != finalURL, fileManager.fileExists(atPath: url.path) {
        try? fileManager.removeItem(at: url)
      }
    }

    if fileManager.fileExists(atPath: session.segmentDirectoryURL.path) {
      try? fileManager.removeItem(at: session.segmentDirectoryURL)
    }
  }

  private func finishSuccessfully() {
    coordinator.releaseRecording()
    recordingSession = nil
    activeSegment = nil
    pendingStartCompletion = nil
    pendingPauseCompletion = nil
    pendingStopCompletion = nil
  }

  private func finishWithFailure(_ error: Error) {
    NativeLogger.e(
      "CameraRecorder",
      "Camera recorder failed",
      context: ["error": error.localizedDescription]
    )
    coordinator.releaseRecording()
    recordingSession = nil
    activeSegment = nil
    pendingStartCompletion = nil
    pendingPauseCompletion = nil
    pendingStopCompletion = nil
  }

  static func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    NativeLogger.d("CameraRecorder", "Camera segment recording started", context: ["path": fileURL.path])
    pendingStartCompletion?(.success(()))
    pendingStartCompletion = nil
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    if let error {
      pendingStartCompletion?(.failure(error))
      pendingPauseCompletion?(.failure(error))
      if let completion = pendingStopCompletion {
        completion(.failure(error))
      }
      finishWithFailure(error)
      return
    }

    guard var session = recordingSession else {
      return
    }

    if let activeSegment {
      let segment = CameraRecordingMetadata.Segment(
        index: activeSegment.index,
        relativePath: activeSegment.url.lastPathComponent,
        startWallClock: Self.iso8601String(from: activeSegment.startedAt),
        endWallClock: Self.iso8601String(from: Date())
      )
      session.segments.append(segment)
      recordingSession = session
    }

    NativeLogger.i(
      "CameraRecorder",
      "Camera segment finished",
      context: ["path": outputFileURL.path, "segments": session.segments.count]
    )

    activeSegment = nil

    if let completion = pendingPauseCompletion {
      pendingPauseCompletion = nil
      completion(.success(()))
      return
    }

    if let completion = pendingStopCompletion {
      pendingStopCompletion = nil
      finalizeStoppedRecording(completion: completion)
    }
  }
}
