import AVFoundation
import Foundation
import FlutterMacOS

struct CameraRecordingMetadata: Codable, Equatable {
  struct Dimensions: Codable, Equatable {
    let width: Int
    let height: Int
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
  var segments: [RecordingMetadata.CaptureSegment]

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
  var segments: [RecordingMetadata.CaptureSegment] = []

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
    if let earliestSegmentStart = segments
      .compactMap({ CameraRecorder.date(from: $0.startWallClock) })
      .min()
    {
      metadata = CameraRecordingMetadata(
        version: metadata.version,
        recordingId: metadata.recordingId,
        rawRelativePath: metadata.rawRelativePath,
        metadataRelativePath: metadata.metadataRelativePath,
        deviceId: metadata.deviceId,
        mirroredRaw: metadata.mirroredRaw,
        nominalFrameRate: metadata.nominalFrameRate,
        dimensions: metadata.dimensions,
        startedAt: CameraRecorder.iso8601String(from: earliestSegmentStart),
        endedAt: metadata.endedAt,
        segments: metadata.segments
      )
    }
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

  var onFailure: ((FlutterError) -> Void)?

  private var recordingSession: CameraRecordingSession?
  private var activeSegment: ActiveCameraSegment?
  private var pendingStartCompletion: ((Result<Void, Error>) -> Void)?
  /// Why the last session ended, kept after `recordingSession` is cleared.
  ///
  /// `stop()` failing with "not active" is only a symptom: the session was
  /// already gone. Without this, all three guards returned the same string
  /// and the cause was undecidable even with full logs — which is exactly
  /// what happened when a take was lost in the field on 2026-07-27.
  enum SessionEnding: String {
    case neverBegan
    case finishedSuccessfully
    case failed
  }

  private(set) var lastSessionEnding: SessionEnding = .neverBegan
  private(set) var lastSessionEndedAt: Date?
  private(set) var lastSessionSegmentCount: Int = 0

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
      // Say which state is refusing. A paused session and one left behind by a
      // start that failed without unwinding look identical from here, and
      // "already active" alone sent the last investigation looking in the
      // wrong place — the recorder was not recording anything.
      let segments = recordingSession?.segments.count ?? 0
      let outputRecording = coordinator.recordingOutput.isRecording
      NativeLogger.w(
        "CameraRecorder",
        "Refusing to begin: a camera session is already held",
        context: [
          "outputIsRecording": outputRecording,
          "hasActiveSegment": activeSegment != nil,
          "segmentsSoFar": segments,
          "lastSessionEnding": lastSessionEnding.rawValue,
        ]
      )
      completion(
        .failure(
          flutterError(
            NativeErrorCode.alreadyRecording,
            "Camera recorder already active (recording: \(outputRecording), "
              + "segments: \(segments))")))
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
      startNextSegment { [weak self] result in
        // Unwind everything this method claimed if the first segment never
        // starts. `recordingSession` is assigned above so `startNextSegment`
        // can read it, and until that call could fail there was nothing to
        // undo — it either started or the process aborted. Now that a
        // not-ready camera is refused instead of fatal, leaving the session
        // assigned makes the recorder look permanently active and every later
        // attempt comes back ALREADY_RECORDING until the app is restarted,
        // which is a worse failure than the crash it replaced.
        //
        // Routed through the existing teardown rather than clearing the
        // fields here: it releases the coordinator's recording use and stamps
        // `lastSessionEnding`, so the next error can say what ended the
        // session instead of just refusing.
        if case .failure(let error) = result {
          self?.finishWithFailure(error)
        }
        completion(result)
      }
    } catch {
      // acquireRecording may have taken the recording use before throwing.
      coordinator.releaseRecording()
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
      completion(
        .failure(
          flutterError(
            NativeErrorCode.notRecording,
            "Camera recorder is not active (resume; ended by: \(lastSessionEnding.rawValue))")))
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
      // The interesting question is never "was it active" — it is what
      // cleared it, and when. Answer that here so the next occurrence is
      // decidable from one log line rather than a code reading.
      let secondsSinceEnd = lastSessionEndedAt.map { Date().timeIntervalSince($0) }
      NativeLogger.e(
        "CameraRecorder",
        "stop() called with no active session",
        context: [
          "endedBy": lastSessionEnding.rawValue,
          "secondsSinceSessionEnded": secondsSinceEnd.map { String(format: "%.3f", $0) } ?? "never",
          "segmentsAtEnd": lastSessionSegmentCount,
          "outputIsRecording": coordinator.recordingOutput.isRecording,
          "hasActiveSegment": activeSegment != nil,
        ])
      completion(
        .failure(
          flutterError(
            NativeErrorCode.notRecording,
            "Camera recorder is not active (ended by: \(lastSessionEnding.rawValue))")))
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
      completion(
        .failure(
          flutterError(
            NativeErrorCode.notRecording,
            "Camera recorder is not active (startNextSegment; ended by: \(lastSessionEnding.rawValue))")))
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

    NativeLogger.i(
      "CameraRecorder",
      "Starting camera segment",
      context: [
        "index": nextIndex,
        "path": segmentURL.path,
        "sessionRunning": coordinator.isSessionRunning,
        "videoConnectionActive": coordinator.hasActiveVideoConnection,
      ]
    )

    // Refuse before AVFoundation has to. `startRecording(to:)` RAISES an
    // Objective-C exception when the capture graph is not ready — session not
    // running, or no active video connection — and Swift cannot catch those,
    // so the raise reaches the terminate handler and aborts the process. That
    // is a real crash seen in the field: a camera hot-plugged and selected
    // about ten seconds before recording started, and the first segment start
    // killed the app.
    //
    // Checking here turns the common case into an ordinary start failure with
    // a message the user can act on, and leaves the bridge below to catch the
    // states we cannot enumerate.
    guard coordinator.isSessionRunning, coordinator.hasActiveVideoConnection else {
      let reason =
        coordinator.isSessionRunning
        ? "the camera has no active video connection"
        : "the camera session is not running"
      NativeLogger.e(
        "CameraRecorder",
        "Refusing to start a camera segment before the capture graph is ready",
        context: [
          "index": nextIndex,
          "sessionRunning": coordinator.isSessionRunning,
          "videoConnectionActive": coordinator.hasActiveVideoConnection,
        ]
      )
      completion(
        .failure(
          flutterError(
            NativeErrorCode.recordingError,
            "The camera is not ready to record — \(reason). "
              + "If you just connected or switched cameras, wait a moment and try again.")))
      return
    }

    activeSegment = ActiveCameraSegment(index: nextIndex, url: segmentURL, startedAt: Date())
    pendingStartCompletion = completion

    do {
      try AVCaptureMovieFileOutputExceptionBridge.startRecording(
        output: coordinator.recordingOutput,
        outputURL: segmentURL,
        recordingDelegate: self
      )
      scheduleSegmentStartTimeout(index: nextIndex)
    } catch {
      // The delegate never fires when the start is refused, so the pending
      // completion would otherwise be held forever and the UI would sit in
      // "starting" until the user force-quits.
      activeSegment = nil
      pendingStartCompletion = nil
      let nsError = error as NSError
      NativeLogger.e(
        "CameraRecorder",
        "Camera refused to start recording",
        context: [
          "index": nextIndex,
          "exceptionName": nsError.userInfo["exceptionName"] ?? "",
          "exceptionReason": nsError.userInfo["exceptionReason"] ?? "",
          "hasVideoConnection": nsError.userInfo["hasVideoConnection"] ?? "",
          "videoConnectionActive": nsError.userInfo["videoConnectionActive"] ?? "",
          "outputIsRecording": nsError.userInfo["outputIsRecording"] ?? "",
        ]
      )
      completion(.failure(error))
    }
  }

  /// How long to wait for AVFoundation to confirm a camera segment started.
  ///
  /// Measured, not guessed. On a healthy start the delegate confirms in about
  /// 1.4s. When the capture session was reconfigured under us, AVFoundation
  /// reported its own error after 14s — which is more informative than a
  /// timeout, so this must sit above that and let it speak. What this exists
  /// for is the third case: with an external camera that stalled, the delegate
  /// did not report for 15 minutes 51 seconds, and the UI span the entire time
  /// with no way out but relaunching the app.
  static let segmentStartTimeoutSeconds: TimeInterval = 20

  /// Distinguishes start attempts so a timer from an abandoned attempt cannot
  /// fail a newer one.
  private var segmentStartToken: UInt64 = 0

  private func scheduleSegmentStartTimeout(index: Int) {
    segmentStartToken &+= 1
    let token = segmentStartToken
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.segmentStartTimeoutSeconds) {
      [weak self] in
      self?.failSegmentStartIfStillPending(token: token, index: index)
    }
  }

  private func failSegmentStartIfStillPending(token: UInt64, index: Int) {
    // Still the current attempt, and still waiting. Either check failing means
    // the delegate answered or the session moved on, and there is nothing to do.
    guard token == segmentStartToken, let completion = pendingStartCompletion else { return }

    let error = flutterError(
      NativeErrorCode.recordingError,
      "The camera did not start recording within "
        + "\(Int(Self.segmentStartTimeoutSeconds)) seconds. "
        + "If it is an external camera, reconnect it or pick a different one, then try again.")
    NativeLogger.e(
      "CameraRecorder",
      "Camera segment start timed out",
      context: [
        "index": index,
        "timeoutSeconds": Self.segmentStartTimeoutSeconds,
        "outputIsRecording": coordinator.recordingOutput.isRecording,
        "sessionRunning": coordinator.isSessionRunning,
        "videoConnectionActive": coordinator.hasActiveVideoConnection,
      ]
    )
    // finishWithFailure clears pendingStartCompletion, so it was captured above.
    // Deliberately does NOT call stopRecording on the output: that method is
    // itself a documented raiser, and it is what threw in the crash report that
    // started this whole thread. Releasing through the normal teardown is the
    // safer unwind.
    finishWithFailure(error)
    completion(.failure(error))
  }

  private func finalizeStoppedRecording(
    completion: @escaping (Result<CameraRecordingResult, Error>) -> Void
  ) {
    guard let session = recordingSession else {
      completion(.failure(flutterError(NativeErrorCode.notRecording, "Camera recorder is not active")))
      return
    }

    let segmentURLs = session.segments.compactMap { segment -> URL? in
      guard let relativePath = segment.relativePath, !relativePath.isEmpty else {
        NativeLogger.w(
          "CameraRecorder",
          "Skipping camera segment with missing relative path during finalize",
          context: ["index": segment.index]
        )
        return nil
      }
      return session.segmentDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
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
      guard let relativePath = segment.relativePath, !relativePath.isEmpty else { continue }
      let url = session.segmentDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
      if url != finalURL, fileManager.fileExists(atPath: url.path) {
        try? fileManager.removeItem(at: url)
      }
    }

    if fileManager.fileExists(atPath: session.segmentDirectoryURL.path) {
      try? fileManager.removeItem(at: session.segmentDirectoryURL)
    }
  }

  private func finishSuccessfully() {
    lastSessionEnding = .finishedSuccessfully
    lastSessionEndedAt = Date()
    lastSessionSegmentCount = recordingSession?.segments.count ?? 0
    coordinator.releaseRecording()
    recordingSession = nil
    activeSegment = nil
    pendingStartCompletion = nil
    pendingPauseCompletion = nil
    pendingStopCompletion = nil
  }

  private func finishWithFailure(_ error: Error) {
    lastSessionEnding = .failed
    lastSessionEndedAt = Date()
    lastSessionSegmentCount = recordingSession?.segments.count ?? 0
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

  static func date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }

  private static func recordingFinishedSuccessfully(_ error: Error?) -> Bool {
    guard let nsError = error as NSError? else { return true }
    return (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
  }

  private static func flutterFailure(from error: Error) -> FlutterError {
    (error as? FlutterError)
      ?? flutterError(NativeErrorCode.recordingError, error.localizedDescription)
  }

#if DEBUG
  static func _testRecordingFinishedSuccessfully(_ error: NSError?) -> Bool {
    recordingFinishedSuccessfully(error)
  }
#endif
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
    let nsError = error as NSError?
    let recordingFinishedSuccessfully = Self.recordingFinishedSuccessfully(error)
    var finishContext: [String: Any] = [
      "path": outputFileURL.path,
      "hasError": error != nil,
      "recordingFinishedSuccessfully": recordingFinishedSuccessfully,
    ]
    if let nsError {
      finishContext["errorDomain"] = nsError.domain
      finishContext["errorCode"] = nsError.code
      finishContext["errorDescription"] = nsError.localizedDescription
      finishContext["errorUserInfo"] = "\(nsError.userInfo)"
    }
    NativeLogger.i("CameraRecorder", "Camera segment finished", context: finishContext)

    if let error, !recordingFinishedSuccessfully {
      let shouldNotifyFailure =
        pendingStartCompletion == nil && pendingPauseCompletion == nil && pendingStopCompletion == nil
      let flutterFailure = Self.flutterFailure(from: error)

      pendingStartCompletion?(.failure(error))
      pendingPauseCompletion?(.failure(error))
      if let completion = pendingStopCompletion {
        completion(.failure(error))
      }
      finishWithFailure(error)

      if shouldNotifyFailure {
        let failureHandler = onFailure
        DispatchQueue.main.async {
          failureHandler?(flutterFailure)
        }
      }
      return
    }

    guard var session = recordingSession else {
      return
    }

    if let activeSegment {
      let finishedAt = Date()
      let mediaDuration = recordedDurationSeconds(
        for: outputFileURL,
        fallback: max(0.0, finishedAt.timeIntervalSince(activeSegment.startedAt))
      )
      let segmentStart = finishedAt.addingTimeInterval(-mediaDuration)
      let segment = RecordingMetadata.CaptureSegment(
        index: activeSegment.index,
        relativePath: activeSegment.url.lastPathComponent,
        startWallClock: Self.iso8601String(from: segmentStart),
        endWallClock: Self.iso8601String(from: finishedAt),
        durationSeconds: mediaDuration
      )
      session.segments.append(segment)
      recordingSession = session
    }

    NativeLogger.i(
      "CameraRecorder",
      "Camera segment committed",
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
}
