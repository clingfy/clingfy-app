import AVFoundation
import AppKit

protocol AVFoundationCapturePipelining: AnyObject {
  var onStarted: ((URL) -> Void)? { get set }
  var onPaused: (() -> Void)? { get set }
  var onResumed: (() -> Void)? { get set }
  var onFinished: ((URL?, Error?) -> Void)? { get set }
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)? { get set }
  var isRecording: Bool { get }
  var isRecordingPaused: Bool { get }
  var currentOutputURL: URL? { get }
  /// The stretches between pauses in the finished file, for camera sync. Set
  /// before `onFinished` is called.
  var recordedScreenSegments: [RecordingMetadata.CaptureSegment] { get }

  func start(
    displayID: CGDirectDisplayID,
    cropRect: CGRect?,
    quality: RecordingQuality,
    frameRate: Int,
    includeAudioDevice: AVCaptureDevice?,
    makeOutputURL: @escaping () throws -> URL
  )
  func stop()
  func pause()
  func resume()
}

final class CapturePipeline: NSObject, AVCaptureFileOutputRecordingDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate, AVFoundationCapturePipelining
{
  private let queue = DispatchQueue(label: "com.clingfy.capture")
  private let audioLevelQueue = DispatchQueue(label: "com.clingfy.capture.audio_level")
  private(set) var session: AVCaptureSession?
  private(set) var movieOutput: AVCaptureMovieFileOutput?
  private var microphoneLevelOutput: AVCaptureAudioDataOutput?
  var onStarted: ((URL) -> Void)?
  var onPaused: (() -> Void)?
  var onResumed: (() -> Void)?
  var onFinished: ((URL?, Error?) -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?

  private let cursorRecorder = CursorRecorder()

  /// Session-scoped sleep hold; see the SCK backend for why it is not

  /// CursorRecorder's job any more.

  let recordingKeepAwake = KeepAwakeSlot()
  private var smoothedMicLevelLinear: Double = 0.0
  private var lastMicLevelEmitAt: CFTimeInterval = 0.0
  private let micLevelEmitInterval: Double = 1.0 / 15.0

  private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
  private var currentCaptureRect: CGRect?
  private var currentCursorRasterScale: Double = 1.0

  // Pause state and the stretches between pauses, as the delegate reported
  // them. Written on AVFoundation's delegate thread and read from the capture
  // queue and the main thread, so behind a lock.
  //
  // `movieOutput.isRecordingPaused` is not used for this. On a live take it
  // still read false three seconds after `didPause` was delivered, so a resume
  // guarded on it returned without resuming, and the take could then neither
  // resume nor stop.
  private var sessionRuntimeErrors: RuntimeErrorRecorder?
  private let stretchLock = NSLock()
  private var pausedByDelegate = false
  private var openStretchStartedAt: Date?
  private var closedStretches: [(start: Date, end: Date)] = []
  private var finishedSegments: [RecordingMetadata.CaptureSegment] = []

  private func withStretches<T>(_ body: () -> T) -> T {
    stretchLock.lock()
    defer { stretchLock.unlock() }
    return body()
  }

  var isRecording: Bool {
    (movieOutput?.isRecording ?? false) || (movieOutput?.isRecordingPaused ?? false)
  }

  var isRecordingPaused: Bool {
    withStretches { pausedByDelegate } || (movieOutput?.isRecordingPaused ?? false)
  }

  var recordedScreenSegments: [RecordingMetadata.CaptureSegment] {
    withStretches { finishedSegments }
  }

  var currentOutputURL: URL? {
    movieOutput?.outputFileURL
  }

  func start(
    displayID: CGDirectDisplayID,
    cropRect: CGRect?,
    quality: RecordingQuality,
    frameRate: Int,
    includeAudioDevice: AVCaptureDevice?,
    makeOutputURL: @escaping () throws -> URL
  ) {
    queue.async { [self] in
      let session = AVCaptureSession()
      session.sessionPreset = .high

      guard let screenInput = AVCaptureScreenInput(displayID: displayID) else {
        self.finishStartError(
          code: "SCREEN_INPUT_ERROR", msg: "Unable to access the selected display.")
        return
      }
      screenInput.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
      screenInput.capturesCursor = false
      screenInput.capturesMouseClicks = false
      if let cropRect {
        screenInput.cropRect = cropRect
      } else {
        screenInput.cropRect = .null
      }

      let movie = AVCaptureMovieFileOutput()
      // Fragment output so abrupt app termination is less likely to leave an unreadable file.
      movie.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 1)

      session.beginConfiguration()
      guard session.canAddInput(screenInput) else {
        session.commitConfiguration()
        self.finishStartError(code: "SCREEN_INPUT_ERROR", msg: "Cannot add screen input.")
        return
      }
      session.addInput(screenInput)

      self.applyQuality(
        screenInput: screenInput,
        displayID: displayID,
        quality: quality,

        captureRect: cropRect
      )
      let displayPointPixelScale = self.displayPointPixelScale(for: displayID)
      let videoDownscaleFactor = max(0.1, Double(screenInput.scaleFactor))
      self.currentCursorRasterScale = self.clampedCursorRasterScale(
        displayPointPixelScale * videoDownscaleFactor)
      NativeLogger.d(
        "AVFBackend", "Cursor raster scale computed",
        context: [
          "displayPointPixelScale": displayPointPixelScale,
          "videoDownscaleFactor": videoDownscaleFactor,
          "cursorRasterScale": self.currentCursorRasterScale,
        ])

      if let audio = includeAudioDevice {
        do {
          let input = try AVCaptureDeviceInput(device: audio)
          if session.canAddInput(input) { session.addInput(input) }
        } catch {
          session.commitConfiguration()
          self.finishStartError(code: "AUDIO_INPUT_ERROR", msg: error.localizedDescription)
          return
        }

        let levelOutput = AVCaptureAudioDataOutput()
        levelOutput.setSampleBufferDelegate(self, queue: self.audioLevelQueue)
        if session.canAddOutput(levelOutput) {
          session.addOutput(levelOutput)
          self.microphoneLevelOutput = levelOutput
        } else {
          NativeLogger.w("AVFBackend", "Cannot add microphone level output")
        }
      } else {
        self.microphoneLevelOutput = nil
      }

      guard session.canAddOutput(movie) else {
        session.commitConfiguration()
        self.finishStartError(code: "OUTPUT_ERROR", msg: "Cannot add movie output.")
        return
      }
      session.addOutput(movie)
      session.commitConfiguration()

      if let vc = movie.connection(with: .video), !vc.isEnabled {
        self.finishStartError(code: "NO_ACTIVE_VIDEO", msg: "Video connection is disabled.")
        return
      }

      do {
        let url = try makeOutputURL()
        self.session = session
        self.movieOutput = movie
        self.resetMicrophoneLevelSmoothing()

        // Persist capture geometry once the session start is confirmed.
        self.currentDisplayID = displayID
        self.currentCaptureRect = cropRect

        let runtimeErrors = RuntimeErrorRecorder(session: session)
        // Kept for the take, so a runtime error mid-recording is logged too.
        self.sessionRuntimeErrors = runtimeErrors
        session.startRunning()

        // Confirm the screen is actually flowing before asking for a file.
        // When macOS will not supply it, `startRunning()` returns at once
        // (about 20ms against 1.4s for a healthy start), the connection never
        // goes active, and the recording start raises "No active/enabled
        // connections". Seen on macOS 26 after the system's capture services
        // were killed under memory pressure. Waiting here lets a slow but
        // healthy start through and turns the rest into a clear error.
        let videoActive = Self.waitForActiveVideo(movie, session: session)
        if let refusal = Self.startRefusal(
          isRunning: session.isRunning, videoConnectionActive: videoActive,
          screenCaptureAllowed: CGPreflightScreenCaptureAccess())
        {
          NativeLogger.e(
            "AVFBackend", "Screen capture is not running; not starting the recording",
            context: [
              "sessionRunning": session.isRunning,
              "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
              "connections": Self.describeConnections(movie),
              "runtimeError": runtimeErrors.lastError.map { RecordingSegmentMerger.describe($0) } ?? "none",
              "code": refusal.code,
            ])
          session.stopRunning()
          self.movieOutput = nil
          self.session = nil
          self.sessionRuntimeErrors = nil
          self.finishStartError(code: refusal.code, msg: refusal.message)
          return
        }

        // Through the bridge: `startRecording(to:)` RAISES when the screen
        // input has no active connection, and Swift cannot catch that, so it
        // aborted the app. Seen forcing this backend on macOS 26: "No
        // active/enabled connections", straight out of a record tap.
        do {
          try AVCaptureMovieFileOutputExceptionBridge.startRecording(
            output: movie, outputURL: url, recordingDelegate: self)
        } catch {
          let nsError = error as NSError
          NativeLogger.e(
            "AVFBackend", "Screen recording refused to start",
            context: [
              "exceptionName": nsError.userInfo["exceptionName"] ?? "",
              "exceptionReason": nsError.userInfo["exceptionReason"] ?? "",
            ])
          session.stopRunning()
          self.movieOutput = nil
          self.session = nil
          self.sessionRuntimeErrors = nil
          self.finishStartError(
            code: "NO_ACTIVE_VIDEO",
            msg: "The screen could not be recorded. Try again, or restart Clingfy if it keeps happening.")
        }
      } catch {
        self.finishStartError(code: "OUTPUT_URL_ERROR", msg: error.localizedDescription)
      }
    }
  }

  func stop() {
    queue.async { self.movieOutput?.stopRecording() }
  }

  /// Why a start must not go ahead, or nil when the screen is flowing.
  ///
  /// With screen recording turned off, the existing permission error with an
  /// empty message, as the facade's own preflight sends it: on macOS Dart
  /// shows the message when there is one, and only an empty one lets it reach
  /// its localized permission text and the button that opens the setting. Otherwise macOS is not
  /// supplying the screen for some other reason; Clingfy cannot fix that, and
  /// a restart of the Mac is what brought it back.
  static func startRefusal(
    isRunning: Bool, videoConnectionActive: Bool, screenCaptureAllowed: Bool
  ) -> (code: String, message: String)? {
    // Permission first: with it off, the connection still reports active and
    // the session fails afterwards with a runtime error ('what') and no
    // frames, so the connection state alone would let the start through.
    if !screenCaptureAllowed {
      return (NativeErrorCode.screenRecordingPermission, "")
    }
    if isRunning && videoConnectionActive { return nil }
    return (
      NativeErrorCode.screenCaptureUnavailable,
      "macOS is not providing the screen to Clingfy right now. "
        + "Restart your Mac, then try again."
    )
  }

  /// The finish errors seen when the screen supplied no frames: "no data
  /// captured", and on macOS 26 a generic -11800 wrapping OSStatus -12780.
  static func isNoFramesError(_ error: NSError) -> Bool {
    guard error.domain == AVFoundationErrorDomain else { return false }
    if error.code == AVError.noDataCaptured.rawValue { return true }
    guard error.code == AVError.unknown.rawValue,
      let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    else { return false }
    return underlying.domain == NSOSStatusErrorDomain && underlying.code == -12780
  }

  /// Polls until the movie output's video connection is active, or the
  /// timeout passes. Runs on the capture queue, which has nothing else to do
  /// while a start is pending.
  static func waitForActiveVideo(
    _ movie: AVCaptureMovieFileOutput, session: AVCaptureSession,
    timeout: TimeInterval = 1.5
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if session.isRunning, movie.connection(with: .video)?.isActive == true { return true }
      if Date() >= deadline { return false }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  static func describeConnections(_ output: AVCaptureOutput) -> String {
    let connections = output.connections
    if connections.isEmpty { return "none" }
    return connections.map { connection in
      let types = connection.inputPorts.map { $0.mediaType.rawValue }.joined(separator: "+")
      return "\(types) enabled=\(connection.isEnabled) active=\(connection.isActive)"
    }.joined(separator: "; ")
  }

  // Already in the asked-for state, these report it again rather than return
  // silently, as the ScreenCaptureKit backend does. The facade waits for the
  // callback, so a silent return holds the pause or resume in flight for good
  // and queues a stop behind it that never runs. That is reachable: a camera
  // that fails to resume leaves the facade paused over a screen that already
  // resumed, and the user's next resume must still be answered.
  func pause() {
    queue.async {
      let isRecording = self.movieOutput?.isRecording ?? false
      switch Self.toggleAction(
        wantPaused: true, isRecording: isRecording,
        isPaused: self.withStretches({ self.pausedByDelegate }))
      {
      case .ignore: return
      case .reportAlreadyThere: DispatchQueue.main.async { self.onPaused?() }
      case .request: self.movieOutput?.pauseRecording()
      }
    }
  }

  func resume() {
    queue.async {
      let isRecording = self.movieOutput?.isRecording ?? false
      switch Self.toggleAction(
        wantPaused: false, isRecording: isRecording,
        isPaused: self.withStretches({ self.pausedByDelegate }))
      {
      case .ignore: return
      case .reportAlreadyThere: DispatchQueue.main.async { self.onResumed?() }
      case .request: self.movieOutput?.resumeRecording()
      }
    }
  }

  enum ToggleAction: Equatable {
    /// Nothing is recording; there is nothing to pause or resume.
    case ignore
    /// Already in the asked-for state: report it again.
    case reportAlreadyThere
    /// Ask AVFoundation, which confirms through the delegate.
    case request
  }

  static func toggleAction(wantPaused: Bool, isRecording: Bool, isPaused: Bool) -> ToggleAction {
    guard isRecording else { return .ignore }
    return isPaused == wantPaused ? .reportAlreadyThere : .request
  }

  private func applyQuality(
    screenInput: AVCaptureScreenInput,
    displayID: CGDirectDisplayID,
    quality: RecordingQuality,

    captureRect: CGRect?
  ) {
    let src: CGSize = {
      if let rect = captureRect {
        return rect.size
      }
      if let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == displayID
      }) {
        let scale = screen.backingScaleFactor
        let pts = screen.frame.size
        return CGSize(width: pts.width * scale, height: pts.height * scale)
      }
      let scale = NSScreen.main?.backingScaleFactor ?? 2.0
      let pts = NSScreen.main?.frame.size ?? .init(width: 1920, height: 1080)
      return .init(width: pts.width * scale, height: pts.height * scale)
    }()

    if quality == .native {
      screenInput.scaleFactor = 1.0
    } else {
      let target = quality.targetSize
      let sx = target.width / max(src.width, 1)
      let sy = target.height / max(src.height, 1)
      screenInput.scaleFactor = min(max(min(sx, sy), 0.1), 1.0)
    }

    if let rect = captureRect {
      screenInput.cropRect = rect
    } else {
      screenInput.cropRect = .null
    }
  }

  private func finishStartError(code: String, msg: String) {
    DispatchQueue.main.async {
      self.onFinished?(nil, flutterError(code, msg))
      // self.onFinished?(nil, flutterError(code, msg))
    }
  }

  private func resetMicrophoneLevelSmoothing() {
    audioLevelQueue.async {
      self.smoothedMicLevelLinear = 0.0
      self.lastMicLevelEmitAt = 0.0
    }
  }

  // MARK: delegate
  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    // The recording's own hold, no longer a side effect of cursor capture
    // being on. Display as well as system: a display that turns off records
    // black frames. Pause and resume below are pass-throughs on this backend,
    // so the hold survives them without extra work.
    let now = Date()
    withStretches {
      pausedByDelegate = false
      openStretchStartedAt = now
      closedStretches = []
      finishedSegments = []
    }
    recordingKeepAwake.acquire(
      reason: "Clingfy is recording your screen", mode: .systemAndDisplay)
    cursorRecorder.start(
      displayID: currentDisplayID,
      captureRect: currentCaptureRect,
      cursorRasterScale: currentCursorRasterScale
    )
    DispatchQueue.main.async {
      self.onStarted?(fileURL)
    }
  }

  // The Swift names of these two must match the protocol exactly. They used to
  // be `captureOutput(_:didPauseRecordingToOutputFileAt:fromConnections:)`,
  // which bound to no Objective-C selector, so AVFoundation never called them:
  // a pause on this backend never reached the facade and the UI sat in
  // "pausing" for good. Pinned by `testAVFoundationPipelinePauseCallbacksBind`.
  func fileOutput(
    _ output: AVCaptureFileOutput,
    didPauseRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    let now = Date()
    withStretches {
      if let start = openStretchStartedAt { closedStretches.append((start, now)) }
      openStretchStartedAt = nil
      pausedByDelegate = true
    }
    cursorRecorder.pause()
    DispatchQueue.main.async {
      self.onPaused?()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didResumeRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    let now = Date()
    withStretches {
      openStretchStartedAt = now
      pausedByDelegate = false
    }
    cursorRecorder.resume()
    DispatchQueue.main.async {
      self.onResumed?()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo url: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    // Released unconditionally and FIRST, not inside the cursor stop
    // completion below. Hanging it off that completion would make the hold's
    // lifetime a property of CursorRecorder again -- the coupling this change
    // exists to remove -- and that closure captures self weakly, so a released
    // pipeline would skip it entirely.
    let finishedAt = Date()
    queue.async { self.sessionRuntimeErrors = nil }
    if let error {
      // The facade only sees "The operation could not be completed". The
      // domain, code and underlying error are what tell a refused screen
      // (no frames ever arrived) from a full disk or a lost display.
      let ns = error as NSError
      NativeLogger.e(
        "AVFBackend", "Screen recording finished with an error",
        context: [
          "error": RecordingSegmentMerger.describe(error),
          "underlying": (ns.userInfo[NSUnderlyingErrorKey] as? Error).map {
            RecordingSegmentMerger.describe($0)
          } ?? "none",
          "finishedSuccessfully": (ns.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool)
            ?? false,
          "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
        ])
    }
    recordingKeepAwake.release()
    microphoneLevelOutput?.setSampleBufferDelegate(nil, queue: nil)
    microphoneLevelOutput = nil
    resetMicrophoneLevelSmoothing()
    self.logFinalVideoInfoAVF(url: url)
    recordFinishedSegments(fileURL: url, finishedAt: finishedAt)

    let cursorURL = RecordingProjectPaths.resolvedCursorDataURL(forScreenVideoURL: url)

    let reportedError = Self.reportedFinishError(
      error,
      fileHasVideo: !AVURLAsset(url: url).tracks(withMediaType: .video).isEmpty,
      screenCaptureAllowed: CGPreflightScreenCaptureAccess())

    cursorRecorder.stop(outputURL: cursorURL) { [weak self] in
      guard let self = self else { return }
      DispatchQueue.main.async {
        self.onFinished?(url, reportedError)
      }
    }
  }

  /// The error to report for a finished file.
  ///
  /// A recording that failed with no video written, in the shapes that mean
  /// no frames ever arrived, means macOS never supplied the screen. Reported
  /// raw, that reached the user as "The operation could not be completed",
  /// which was all a live take on macOS 26 ever said. Anything else passes
  /// through: a full disk or a lost display must keep its own error.
  static func reportedFinishError(
    _ error: Error?, fileHasVideo: Bool, screenCaptureAllowed: Bool
  ) -> Error? {
    guard let error else { return nil }
    let ns = error as NSError
    if (ns.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true { return error }
    if fileHasVideo || !isNoFramesError(ns) { return error }
    if let refusal = startRefusal(
      isRunning: false, videoConnectionActive: false, screenCaptureAllowed: screenCaptureAllowed)
    {
      return flutterError(refusal.code, refusal.message)
    }
    return error
  }
  /// Turns the stretches between pauses into screen segments, all naming the
  /// one file, so the camera can be synced to each.
  ///
  /// The stretches are timed from the delegate's callbacks. The last one's
  /// length is what the file holds beyond the others, so the segments sum to
  /// the file. Without segments, camera sync assumed one
  /// unbroken stretch ending at the stop, and on a paused take the camera
  /// bubble was missing or offset everywhere before the last pause.
  private func recordFinishedSegments(fileURL: URL, finishedAt: Date) {
    let fileDuration = AVURLAsset(url: fileURL).duration.seconds
    withStretches {
      var stretches = closedStretches.map { ($0.start, $0.end, $0.end.timeIntervalSince($0.start)) }
      let committed = stretches.reduce(0) { $0 + $1.2 }
      if fileDuration.isFinite, fileDuration > 0 {
        let rest = fileDuration - committed
        let lastIsOpen = openStretchStartedAt != nil || rest > Self.unconfirmedMediaSeconds
        if lastIsOpen, rest > Self.minimumStretchSeconds {
          // Anchored at its start when that is known: the finish arrives
          // after the file is closed, late by however long that took, and a
          // late screen window shifts the camera against it.
          let start = openStretchStartedAt ?? finishedAt.addingTimeInterval(-rest)
          stretches.append((start, start.addingTimeInterval(rest), rest))
        } else if let last = stretches.indices.last,
          stretches[last].2 + rest > Self.minimumStretchSeconds
        {
          // Ended paused, or the clock ran ahead of the media: square the last
          // stretch with the file, so the error does not shift what follows.
          let duration = stretches[last].2 + rest
          stretches[last] = (stretches[last].0, stretches[last].0.addingTimeInterval(duration), duration)
        }
      }
      finishedSegments = stretches
        .filter { $0.2 > Self.minimumStretchSeconds }
        .enumerated()
        .map { index, stretch in
          RecordingMetadata.CaptureSegment(
            index: index,
            relativePath: fileURL.lastPathComponent,
            startWallClock: RecordingMetadata.iso8601String(from: stretch.0),
            endWallClock: RecordingMetadata.iso8601String(from: stretch.1),
            durationSeconds: stretch.2
          )
        }
      // A file the asset cannot read gets no segments: sync then falls back to
      // the stop time, as it always did on this backend.
      if !(fileDuration.isFinite && fileDuration > 0) { finishedSegments = [] }
      closedStretches = []
      openStretchStartedAt = nil
      pausedByDelegate = false
    }
  }

  /// Shorter than this is not a stretch. The sync resolver refuses a timeline
  /// containing one, which would cost the take its camera sync.
  static let minimumStretchSeconds: TimeInterval = 0.0001

  /// Media past the last confirmed pause beyond this is real footage, not
  /// clock error, and is kept as its own stretch.
  static let unconfirmedMediaSeconds: TimeInterval = 0.1

  private func logFinalVideoInfoAVF(url: URL) {
    let asset = AVURLAsset(url: url)

    guard let track = asset.tracks(withMediaType: .video).first else {
      NativeLogger.w("AVFBackend", "No video track found", context: ["url": url.path])
      return
    }

    let t = track.preferredTransform
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(t)
    let w = abs(rect.width)
    let h = abs(rect.height)

    let bytes =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .doubleValue ?? 0

    let seconds = max(asset.duration.seconds, 0.001)
    let bpsFromFile = (bytes * 8.0) / seconds

    NativeLogger.i(
      "AVFBackend", "Final video track info",
      context: [
        "url": url.path,
        "w": w,
        "h": h,
        "nominalFps": track.nominalFrameRate,
        "estimatedDataRate_bps": track.estimatedDataRate,
        "file_bytes": bytes,
        "duration_s": seconds,
        "bitrate_from_file_bps": bpsFromFile,
      ])
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard output === microphoneLevelOutput else { return }
    guard let estimate = AudioLevelEstimator.estimatePeak(sampleBuffer: sampleBuffer) else {
      return
    }

    let alpha = estimate.linear >= smoothedMicLevelLinear ? 0.35 : 0.18
    smoothedMicLevelLinear =
      smoothedMicLevelLinear * (1.0 - alpha) + estimate.linear * alpha

    let now = CFAbsoluteTimeGetCurrent()
    if now - lastMicLevelEmitAt < micLevelEmitInterval {
      return
    }
    lastMicLevelEmitAt = now

    let sample = MicrophoneLevelSample(
      linear: smoothedMicLevelLinear,
      dbfs: AudioLevelEstimator.dbfs(for: smoothedMicLevelLinear)
    )

    DispatchQueue.main.async {
      self.onMicrophoneLevel?(sample)
    }
  }

  private func displayPointPixelScale(for displayID: CGDirectDisplayID) -> Double {
    if let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        == displayID
    }) {
      return Double(screen.backingScaleFactor)
    }

    let bounds = CGDisplayBounds(displayID)
    if bounds.width > 0 {
      return max(0.1, Double(CGDisplayPixelsWide(displayID)) / Double(bounds.width))
    }
    return 1.0
  }

  private func clampedCursorRasterScale(_ value: Double) -> Double {
    min(max(value, 0.1), 8.0)
  }

}

/// Keeps the last `AVCaptureSessionRuntimeError` a session posted, so a start
/// that fails can say what AVFoundation reported. Nothing logged it before,
/// which left the macOS 26 refusals with no cause on record.
private final class RuntimeErrorRecorder {
  private let lock = NSLock()
  private var error: Error?
  private var observer: NSObjectProtocol?

  init(session: AVCaptureSession) {
    observer = NotificationCenter.default.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
    ) { [weak self] note in
      let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
      NativeLogger.e(
        "AVFBackend", "Capture session runtime error",
        context: ["error": error.map { RecordingSegmentMerger.describe($0) } ?? "unknown"])
      self?.lock.lock()
      self?.error = error
      self?.lock.unlock()
    }
  }

  var lastError: Error? {
    lock.lock()
    defer { lock.unlock() }
    return error
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }
}
