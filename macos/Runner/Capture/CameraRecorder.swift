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

/// The camera file currently open, and where its stretches stand.
///
/// A pause no longer ends the file. It pauses it in place, and a resume carries
/// on in the same file, so one file holds every stretch of the take between
/// pauses. Each stretch is committed as its own `CaptureSegment`, all naming
/// this file, because the sync resolver maps the camera onto the screen's
/// timeline stretch by stretch.
private struct ActiveCameraSegment {
  let index: Int
  let url: URL
  let startedAt: Date
  /// When the stretch being recorded began: the `didStart` or `didResume`
  /// callback. Nil until the start is confirmed, and while paused.
  var stretchStartedAt: Date?
  /// Seconds of this file already committed as stretches.
  var committedSeconds: TimeInterval = 0
  /// Paused in place, confirmed by `didPause`.
  var isPaused = false
  /// We asked for this file to end. Anything else ending it is a surprise.
  var stopRequested = false
}

/// Joins a take's camera files. Most takes are one file (a pause pauses in
/// place), which is simply moved. Several files come only from a fallback: a
/// refused or unconfirmed pause or resume, or a file a device or format change
/// ended. Those are the files most likely to differ, so this uses the screen
/// merger's tested composition (audio matched by format, inserts clamped to
/// each track) and does not stop at passthrough.
private enum CameraMergeUtility {
  static func mergeSegments(
    _ segmentURLs: [URL],
    to outputURL: URL,
    presets: [String],
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    // One file, the common case, is moved here and now, as it always was: no
    // asynchronous gap, and a leftover output that cannot be removed does not
    // fail the take.
    if segmentURLs.count == 1 {
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: outputURL.path) {
        try? fileManager.removeItem(at: outputURL)
      }
      do {
        try fileManager.moveItem(at: segmentURLs[0], to: outputURL)
        completion(.success(outputURL))
      } catch {
        completion(.failure(error))
      }
      return
    }
    Task {
      do {
        let outcome = try await RecordingSegmentMerger.mergeSegments(
          segmentURLs, to: outputURL, presets: presets)
        if let preset = outcome.preset, preset != AVAssetExportPresetPassthrough {
          NativeLogger.w(
            "CameraRecorder", "Camera parts did not pass through; re-encoded to join them",
            context: ["preset": preset, "parts": segmentURLs.count])
        }
        DispatchQueue.main.async { completion(.success(outcome.url)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }
}

final class CameraRecorder: NSObject {
  private let coordinator: CameraCaptureCoordinating
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
  private var pendingResumeCompletion: ((Result<Void, Error>) -> Void)?
  private var pendingStopCompletion: ((Result<CameraRecordingResult, Error>) -> Void)?
  /// Names the next camera file. Separate from the segment count because one
  /// file can now hold several segments, or none if every stretch was empty.
  private var nextFileIndex = 0

  /// How long to wait for AVFoundation to confirm a segment started.
  ///
  /// Injectable so a test does not have to wait the real 20 seconds to prove
  /// the backstop fires.
  private let segmentStartTimeout: TimeInterval

  /// How long to wait for `didPause` or `didResume` before giving up on the
  /// in-place path and ending the file, which is what a pause used to do.
  private let pauseResumeTimeout: TimeInterval

  /// Passthrough first; then re-encode, HEVC and then H.264 for a Mac without
  /// an HEVC encoder. Injectable so a test can make every attempt fail.
  static let mergePresetOrder = [
    AVAssetExportPresetPassthrough, AVAssetExportPresetHEVCHighestQuality,
    AVAssetExportPresetHighestQuality,
  ]
  private let mergePresets: [String]

  init(
    coordinator: CameraCaptureCoordinating,
    fileManager: FileManager = .default,
    segmentStartTimeout: TimeInterval = CameraRecorder.segmentStartTimeoutSeconds,
    pauseResumeTimeout: TimeInterval = CameraRecorder.pauseResumeTimeoutSeconds,
    mergePresets: [String] = CameraRecorder.mergePresetOrder
  ) {
    self.coordinator = coordinator
    self.fileManager = fileManager
    self.segmentStartTimeout = segmentStartTimeout
    self.pauseResumeTimeout = pauseResumeTimeout
    self.mergePresets = mergePresets
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
      let outputRecording = coordinator.isOutputRecording
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
      nextFileIndex = 0
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

  /// Measured on a real camera: `didPause` arrives about 25ms after the call
  /// and `didResume` about 60ms. Two seconds is far past either and still
  /// short enough that a stalled pause does not hold the UI.
  static let pauseResumeTimeoutSeconds: TimeInterval = 2

  /// Pauses the open file in place.
  ///
  /// A pause used to end the file and a resume start a new one, and that start
  /// costs about 1.1 seconds before AVFoundation records a frame. The screen
  /// resumed at once, so the camera came back a second late on every resume.
  /// Pausing in place keeps the file and its encoder open, and resuming is
  /// confirmed in about 60ms.
  func pause(completion: @escaping (Result<Void, Error>) -> Void) {
    guard recordingSession != nil else {
      completion(.success(()))
      return
    }

    guard coordinator.isOutputRecording, let segment = activeSegment, !segment.isPaused,
      !segment.stopRequested
    else {
      completion(.success(()))
      return
    }

    pendingPauseCompletion = completion

    // Not confirmed started yet, so there is no stretch to close. End the file
    // as a pause always used to; the resume starts a new one.
    guard segment.stretchStartedAt != nil else {
      endFileForPause(reason: "start not yet confirmed")
      return
    }

    do {
      try coordinator.pauseOutputRecording()
      schedulePauseResumeTimeout()
    } catch {
      let nsError = error as NSError
      NativeLogger.w(
        "CameraRecorder", "Camera refused to pause in place; ending the file instead",
        context: [
          "exceptionName": nsError.userInfo["exceptionName"] ?? "",
          "exceptionReason": nsError.userInfo["exceptionReason"] ?? "",
        ])
      endFileForPause(reason: "pause refused")
    }
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

    // Asked to resume before the pause was confirmed. Without this the resume
    // would find the file still recording and do nothing, and the pause would
    // then land and leave the camera paused for the rest of the take.
    if let segment = activeSegment, !segment.isPaused, pendingPauseCompletion != nil {
      pendingResumeCompletion = completion
      return
    }

    if let segment = activeSegment, segment.isPaused {
      pendingResumeCompletion = completion
      resumePausedFile()
      return
    }

    guard activeSegment == nil, !coordinator.isOutputRecording else {
      completion(.success(()))
      return
    }

    startNextSegment(completion: completion)
  }

  /// Resumes the paused file in place, or ends it so the pending resume
  /// continues in a new file once `didFinish` has committed it.
  private func resumePausedFile() {
    guard let segment = activeSegment, segment.isPaused else { return }

    // The file can end while paused: a device or format change stops the
    // output even then. Its didFinish may not have arrived yet; when it does,
    // the pending resume continues in a new file.
    guard coordinator.isOutputRecording, coordinator.isOutputRecordingPaused,
      !segment.stopRequested
    else {
      NativeLogger.w(
        "CameraRecorder", "Paused camera file is no longer open; resuming in a new file",
        context: [
          "outputIsRecording": coordinator.isOutputRecording,
          "outputIsPaused": coordinator.isOutputRecordingPaused,
        ])
      if coordinator.isOutputRecording, !segment.stopRequested { endFile() }
      return
    }

    do {
      try coordinator.resumeOutputRecording()
      schedulePauseResumeTimeout()
    } catch {
      let nsError = error as NSError
      NativeLogger.w(
        "CameraRecorder", "Camera refused to resume in place; resuming in a new file",
        context: [
          "exceptionName": nsError.userInfo["exceptionName"] ?? "",
          "exceptionReason": nsError.userInfo["exceptionReason"] ?? "",
        ])
      endFile()
    }
  }

  /// Ends the open file so `didFinish` completes the pending pause, which is
  /// how a pause worked before it could pause in place.
  private func endFileForPause(reason: String) {
    NativeLogger.i("CameraRecorder", "Ending the camera file for a pause", context: ["reason": reason])
    endFile()
  }

  private func endFile() {
    guard var segment = activeSegment else { return }
    segment.stopRequested = true
    activeSegment = segment
    coordinator.stopOutputRecording()
  }

  /// A stop waiting on a didFinish that is already in flight. If it never
  /// arrives, finalize with what was committed rather than hold the stop.
  private func scheduleStopBackstop(for url: URL) {
    DispatchQueue.main.asyncAfter(deadline: .now() + pauseResumeTimeout) { [weak self] in
      guard let self, let completion = self.pendingStopCompletion,
        self.activeSegment?.url == url
      else { return }
      NativeLogger.w(
        "CameraRecorder", "Camera file never reported finishing; finalizing without it",
        context: ["path": url.path, "timeoutSeconds": self.pauseResumeTimeout])
      self.pendingStopCompletion = nil
      self.pendingResumeCompletion = nil
      self.activeSegment = nil
      self.finalizeStoppedRecording(completion: completion)
    }
  }

  /// Distinguishes pause and resume requests so a timer from an earlier one
  /// cannot act on a later one.
  private var pauseResumeToken: UInt64 = 0

  private func schedulePauseResumeTimeout() {
    pauseResumeToken &+= 1
    let token = pauseResumeToken
    DispatchQueue.main.asyncAfter(deadline: .now() + pauseResumeTimeout) { [weak self] in
      self?.endFileIfPauseOrResumeStillPending(token: token)
    }
  }

  /// AVFoundation did not confirm in time. Fall back to ending the file: a
  /// pending pause completes on its didFinish, and a pending resume continues
  /// in a new file. Either way the take keeps going.
  private func endFileIfPauseOrResumeStillPending(token: UInt64) {
    guard token == pauseResumeToken, activeSegment?.stopRequested == false else { return }
    let waitingFor: String
    if pendingPauseCompletion != nil {
      waitingFor = "pause"
    } else if pendingResumeCompletion != nil {
      waitingFor = "resume"
    } else {
      return
    }
    NativeLogger.w(
      "CameraRecorder", "Camera did not confirm in time; ending the file instead",
      context: ["waitingFor": waitingFor, "timeoutSeconds": pauseResumeTimeout])
    endFile()
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
          "outputIsRecording": coordinator.isOutputRecording,
          "hasActiveSegment": activeSegment != nil,
        ])
      completion(
        .failure(
          flutterError(
            NativeErrorCode.notRecording,
            "Camera recorder is not active (ended by: \(lastSessionEnding.rawValue))")))
      return
    }

    if let segment = activeSegment {
      // A second stop while the first is still ending the file joins it.
      // Replacing the first completion left its caller unanswered for good.
      if let earlier = pendingStopCompletion {
        pendingStopCompletion = { result in
          earlier(result)
          completion(result)
        }
        return
      }
      pendingStopCompletion = completion
      // Still true while paused in place, which is what ends a paused file.
      if coordinator.isOutputRecording, !segment.stopRequested {
        endFile()
      } else {
        // The file already ended and its didFinish is on its way. Finalizing
        // now would merge a file AVFoundation may still be writing, and drop
        // its last stretch.
        scheduleStopBackstop(for: segment.url)
      }
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

    let nextIndex = nextFileIndex
    nextFileIndex += 1
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
      try coordinator.startOutputRecording(to: segmentURL, delegate: self)
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
    DispatchQueue.main.asyncAfter(deadline: .now() + segmentStartTimeout) {
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
        + "\(Int(segmentStartTimeout)) seconds. "
        + "If it is an external camera, reconnect it or pick a different one, then try again.")
    NativeLogger.e(
      "CameraRecorder",
      "Camera segment start timed out",
      context: [
        "index": index,
        "timeoutSeconds": segmentStartTimeout,
        "outputIsRecording": coordinator.isOutputRecording,
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

  /// Completions waiting on a finalize already under way. A second stop, or
  /// the stop backstop firing after the finish already finalized, would
  /// otherwise merge again: the second merge deletes the file the first just
  /// produced, and both report.
  private var finalizeWaiters: [(Result<CameraRecordingResult, Error>) -> Void]?
  /// The camera's recording use was given back when the files were done, so
  /// the teardown must not give it back again.
  private var recordingUseReleasedEarly = false

  private func finalizeStoppedRecording(
    completion: @escaping (Result<CameraRecordingResult, Error>) -> Void
  ) {
    if finalizeWaiters != nil {
      finalizeWaiters?.append(completion)
      return
    }
    guard let session = recordingSession else {
      completion(.failure(flutterError(NativeErrorCode.notRecording, "Camera recorder is not active")))
      return
    }
    finalizeWaiters = [completion]
    let completion: (Result<CameraRecordingResult, Error>) -> Void = { [weak self] result in
      let waiters = self?.finalizeWaiters ?? []
      self?.finalizeWaiters = nil
      waiters.forEach { $0(result) }
    }
    // Every file is written. Give the camera back now rather than after the
    // merge: a re-encode can take a while, and holding the recording use for it
    // keeps camera changes waiting and the camera running for nothing.
    coordinator.releaseRecording()
    recordingUseReleasedEarly = true

    // Every stretch recorded into one file names that file, so merge each file
    // once, in order. Merging it once per stretch would repeat the take.
    var seenPaths = Set<String>()
    let segmentURLs = session.segments.compactMap { segment -> URL? in
      if let relativePath = segment.relativePath, !seenPaths.insert(relativePath).inserted {
        return nil
      }
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

    CameraMergeUtility.mergeSegments(segmentURLs, to: session.outputURL, presets: mergePresets) {
      [weak self] result in
      guard let self else { return }

      switch result {
      case .failure(let error):
        // The take's camera is lost, but its parts are not: they stay in the
        // segments folder, described by a manifest, instead of lying there
        // with nothing pointing at them.
        self.writeUnmergedManifest(for: session, segmentURLs: segmentURLs, error: error)
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

  /// The manifest beside the camera folder that says what the kept parts
  /// are: the same shape the screen side writes, with each file's stretches
  /// and the camera's details.
  static let unmergedManifestName = RecordingSegmentMerger.unmergedManifestName

  private func writeUnmergedManifest(
    for session: CameraRecordingSession, segmentURLs: [URL], error: Error
  ) {
    let records: [[String: Any]] = segmentURLs.enumerated().map { index, url in
      let name = url.lastPathComponent
      let stretches = session.segments.filter { $0.relativePath == name }.map { segment -> [String: Any] in
        [
          "startWallClock": segment.startWallClock,
          "endWallClock": segment.endWallClock,
          "durationSeconds": segment.durationSeconds ?? 0,
        ]
      }
      var record: [String: Any] = [
        "index": index,
        "camera": "segments/\(name)",
        "present": fileManager.fileExists(atPath: url.path),
        "stretches": stretches,
        "mirroredRaw": session.mirroredRaw,
      ]
      if let deviceId = session.deviceId { record["deviceId"] = deviceId }
      if let fps = session.nominalFrameRate { record["nominalFrameRate"] = fps }
      return record
    }
    let manifestURL = session.segmentDirectoryURL.deletingLastPathComponent()
      .appendingPathComponent(Self.unmergedManifestName)
    guard
      let data = RecordingSegmentMerger.unmergedManifest(
        segments: records, publishedIndex: nil, reason: RecordingSegmentMerger.describe(error))
    else { return }
    do {
      try data.write(to: manifestURL, options: .atomic)
      NativeLogger.w(
        "CameraRecorder", "Camera parts could not be joined; kept with a manifest",
        context: ["manifest": manifestURL.path, "parts": segmentURLs.count])
    } catch {
      NativeLogger.e(
        "CameraRecorder", "Could not write the camera parts manifest",
        context: ["error": error.localizedDescription])
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
    if !recordingUseReleasedEarly { coordinator.releaseRecording() }
    recordingUseReleasedEarly = false
    recordingSession = nil
    activeSegment = nil
    pendingStartCompletion = nil
    pendingPauseCompletion = nil
    pendingResumeCompletion = nil
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
    if !recordingUseReleasedEarly { coordinator.releaseRecording() }
    recordingUseReleasedEarly = false
    recordingSession = nil
    activeSegment = nil
    pendingStartCompletion = nil
    pendingPauseCompletion = nil
    pendingResumeCompletion = nil
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
  // AVFoundation calls these on no particular thread. Each one reads the clock
  // where it is called, because that moment is what stamps a stretch, and then
  // does its work on the main thread, where every other piece of this state is
  // touched. One serial queue also keeps them in the order they were sent.

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    let now = Date()
    DispatchQueue.main.async { [weak self] in
      self?.handleDidStart(fileURL: fileURL, at: now)
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didPauseRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    let now = Date()
    DispatchQueue.main.async { [weak self] in
      self?.handleDidPause(fileURL: fileURL, at: now)
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didResumeRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    let now = Date()
    DispatchQueue.main.async { [weak self] in
      self?.handleDidResume(fileURL: fileURL, at: now)
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    let now = Date()
    DispatchQueue.main.async { [weak self] in
      self?.handleDidFinish(outputFileURL: outputFileURL, error: error, at: now)
    }
  }

  private func handleDidStart(fileURL: URL, at now: Date) {
    NativeLogger.d("CameraRecorder", "Camera segment recording started", context: ["path": fileURL.path])
    if var segment = activeSegment, segment.url.lastPathComponent == fileURL.lastPathComponent {
      segment.stretchStartedAt = now
      activeSegment = segment
    }
    pendingStartCompletion?(.success(()))
    pendingStartCompletion = nil
  }

  private func handleDidPause(fileURL: URL, at now: Date) {
    // Ignored once the file is being ended: the fallback took over, and the
    // file's tail is committed from its real duration in didFinish.
    guard var segment = activeSegment, segment.url.lastPathComponent == fileURL.lastPathComponent, !segment.stopRequested,
      let stretchStart = segment.stretchStartedAt
    else {
      NativeLogger.d("CameraRecorder", "Ignoring camera pause confirmation", context: ["path": fileURL.path])
      return
    }

    let duration = max(0, now.timeIntervalSince(stretchStart))
    commitStretch(of: segment, start: stretchStart, end: now, duration: duration)
    segment.committedSeconds += duration
    segment.stretchStartedAt = nil
    segment.isPaused = true
    activeSegment = segment

    NativeLogger.i(
      "CameraRecorder", "Camera paused in place",
      context: ["path": fileURL.path, "stretchSeconds": duration])

    pauseResumeToken &+= 1
    if let completion = pendingPauseCompletion {
      pendingPauseCompletion = nil
      completion(.success(()))
    }
    if pendingResumeCompletion != nil {
      resumePausedFile()
    }
  }

  private func handleDidResume(fileURL: URL, at now: Date) {
    guard var segment = activeSegment, segment.url.lastPathComponent == fileURL.lastPathComponent, segment.isPaused,
      !segment.stopRequested
    else {
      NativeLogger.d("CameraRecorder", "Ignoring camera resume confirmation", context: ["path": fileURL.path])
      return
    }

    segment.isPaused = false
    segment.stretchStartedAt = now
    activeSegment = segment

    NativeLogger.i("CameraRecorder", "Camera resumed in place", context: ["path": fileURL.path])

    pauseResumeToken &+= 1
    if let completion = pendingResumeCompletion {
      pendingResumeCompletion = nil
      completion(.success(()))
    }
  }

  private func handleDidFinish(outputFileURL: URL, error: Error?, at finishedAt: Date) {
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

    // Nobody asked for this file to end: no stop and no start in flight. A
    // pause no longer ends the file, so a pending one does not explain it.
    // That is how the camera went silent after every resume, with an info line
    // nobody would read. Say it loudly.
    if let segment = activeSegment, !segment.stopRequested, pendingStartCompletion == nil {
      finishContext["wasPaused"] = segment.isPaused
      NativeLogger.e(
        "CameraRecorder", "Camera recording stopped on its own mid-take", context: finishContext)
    }

    if let error, !recordingFinishedSuccessfully {
      let shouldNotifyFailure =
        pendingStartCompletion == nil && pendingPauseCompletion == nil
        && pendingResumeCompletion == nil && pendingStopCompletion == nil
      let flutterFailure = Self.flutterFailure(from: error)

      pendingStartCompletion?(.failure(error))
      pendingPauseCompletion?(.failure(error))
      pendingResumeCompletion?(.failure(error))
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

    guard recordingSession != nil else {
      return
    }

    // The stretch still open when the file ended. Its length is what the file
    // holds beyond the stretches already committed, which makes the stretches
    // sum to the file exactly.
    if let segment = activeSegment, !segment.isPaused {
      let openSince = segment.stretchStartedAt ?? segment.startedAt
      let fileDuration = recordedDurationSeconds(
        for: outputFileURL,
        fallback: segment.committedSeconds + max(0.0, finishedAt.timeIntervalSince(openSince))
      )
      let tail = max(0, fileDuration - segment.committedSeconds)
      // Ended in place of a pause, possibly seconds after the pause took
      // effect, so the finish time says nothing about when this stretch
      // stopped. Its start does.
      if pendingPauseCompletion != nil, let stretchStart = segment.stretchStartedAt {
        commitStretch(
          of: segment, start: stretchStart, end: stretchStart.addingTimeInterval(tail),
          duration: tail)
      } else {
        commitStretch(
          of: segment, start: finishedAt.addingTimeInterval(-tail), end: finishedAt, duration: tail)
      }
    } else if let segment = activeSegment, segment.isPaused {
      // A paused file has no open stretch, but its stretches were timed by the
      // clock, which runs a few tens of milliseconds off the media. With no
      // last stretch to absorb that, square the file's last one with its real
      // duration, or a later file in the merge starts off by the difference.
      let fileDuration = recordedDurationSeconds(
        for: outputFileURL, fallback: segment.committedSeconds)
      let drift = fileDuration - segment.committedSeconds
      if drift > Self.unconfirmedMediaSeconds {
        // More than clock error: a resume took effect but its confirmation
        // was dropped once the file was being ended. That media is real, so
        // keep it as its own stretch ending when the file did.
        commitStretch(
          of: segment, start: finishedAt.addingTimeInterval(-drift), end: finishedAt,
          duration: drift)
      } else {
        reconcileLastStretch(of: segment, by: drift)
      }
    }

    NativeLogger.i(
      "CameraRecorder",
      "Camera segment committed",
      context: ["path": outputFileURL.path, "segments": recordingSession?.segments.count ?? 0]
    )

    activeSegment = nil
    pauseResumeToken &+= 1

    if let completion = pendingPauseCompletion {
      pendingPauseCompletion = nil
      completion(.success(()))
    }

    if let completion = pendingStopCompletion {
      pendingStopCompletion = nil
      pendingResumeCompletion = nil
      finalizeStoppedRecording(completion: completion)
      return
    }

    // A resume was waiting on this file, which can no longer continue it.
    if let completion = pendingResumeCompletion {
      pendingResumeCompletion = nil
      startNextSegment(completion: completion)
    }
  }

  /// Seconds below which a stretch is not committed. The sync resolver refuses
  /// a camera timeline containing any segment this short, so one empty stretch
  /// would cost the whole take its camera sync.
  static let minimumStretchSeconds: TimeInterval = 0.0001

  /// How far a paused file's media may run past its committed stretches and
  /// still be clock error. Measured at about 25ms per stretch.
  static let unconfirmedMediaSeconds: TimeInterval = 0.1

  private func reconcileLastStretch(of segment: ActiveCameraSegment, by drift: TimeInterval) {
    guard abs(drift) > Self.minimumStretchSeconds, var session = recordingSession,
      let last = session.segments.lastIndex(where: {
        $0.relativePath == segment.url.lastPathComponent
      })
    else { return }
    let old = session.segments[last]
    let duration = (old.durationSeconds ?? 0) + drift
    guard duration > Self.minimumStretchSeconds,
      let start = Self.date(from: old.startWallClock)
    else { return }
    NativeLogger.i(
      "CameraRecorder", "Squared the paused file's last stretch with its media",
      context: ["path": segment.url.lastPathComponent, "driftSeconds": drift])
    session.segments[last] = RecordingMetadata.CaptureSegment(
      index: old.index,
      relativePath: old.relativePath,
      startWallClock: old.startWallClock,
      endWallClock: Self.iso8601String(from: start.addingTimeInterval(duration)),
      durationSeconds: duration
    )
    recordingSession = session
  }

  private func commitStretch(
    of segment: ActiveCameraSegment, start: Date, end: Date, duration: TimeInterval
  ) {
    guard var session = recordingSession else { return }
    guard duration > Self.minimumStretchSeconds else {
      NativeLogger.d(
        "CameraRecorder", "Skipping an empty camera stretch",
        context: ["path": segment.url.lastPathComponent, "seconds": duration])
      return
    }
    session.segments.append(
      RecordingMetadata.CaptureSegment(
        index: session.segments.count,
        relativePath: segment.url.lastPathComponent,
        startWallClock: Self.iso8601String(from: start),
        endWallClock: Self.iso8601String(from: end),
        durationSeconds: duration
      ))
    recordingSession = session
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
