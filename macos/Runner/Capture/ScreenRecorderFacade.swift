import AVFoundation
import AppKit
import ApplicationServices
import AudioToolbox
import FlutterMacOS

protocol CaptureControlling: AnyObject {
  var isRecording: Bool { get }
  func start(
    includeAudio: Bool,
    to url: URL,
    didStart: @escaping (URL) -> Void,
    didFail: @escaping (Error) -> Void)
  // func stop(didFinish: @escaping (Result<URL, Error>) -> Void)
  func stop(didFinish: @escaping (Result<URL, FlutterError>) -> Void)

}

struct OverlayUpdateDeduper {
  private var hasLastSentValue = false
  private(set) var lastSentWindowID: CGWindowID?

  mutating func shouldSend(_ windowID: CGWindowID?) -> Bool {
    if hasLastSentValue && lastSentWindowID == windowID {
      return false
    }

    hasLastSentValue = true
    lastSentWindowID = windowID
    return true
  }

  mutating func reset() {
    hasLastSentValue = false
    lastSentWindowID = nil
  }
}

enum AudioLevelEstimator {
  static func dbfs(for linear: Double) -> Double {
    let clamped = max(linear, 0.000000001)
    return 20.0 * log10(clamped)
  }

  static func estimatePeak(sampleBuffer: CMSampleBuffer) -> (linear: Double, dbfs: Double)? {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return nil }

    let asbd = asbdPtr.pointee
    let channelCount = max(1, Int(asbd.mChannelsPerFrame))
    let bufferListSize =
      MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
    let rawPointer = UnsafeMutableRawPointer.allocate(
      byteCount: bufferListSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }
    let audioBufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: audioBufferListPointer,
      bufferListSize: bufferListSize,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return nil }
    let audioBufferList = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)

    let flags = asbd.mFormatFlags
    let bitsPerChannel = asbd.mBitsPerChannel
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInt = (flags & kAudioFormatFlagIsSignedInteger) != 0
    var peak = 0.0

    if isFloat && bitsPerChannel == 32 {
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<sampleCount {
          let value = Double(abs(samples[i]))
          if value > peak { peak = value }
        }
      }
    } else if isFloat && bitsPerChannel == 64 {
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
        let samples = data.assumingMemoryBound(to: Double.self)
        for i in 0..<sampleCount {
          let value = abs(samples[i])
          if value > peak { peak = value }
        }
      }
    } else if isSignedInt && bitsPerChannel == 16 {
      let denom = Double(Int16.max)
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
        let samples = data.assumingMemoryBound(to: Int16.self)
        for i in 0..<sampleCount {
          let sample = samples[i]
          let value =
            sample == Int16.min ? 1.0 : (Double(abs(Int(sample))) / denom)
          if value > peak { peak = value }
        }
      }
    } else if isSignedInt && bitsPerChannel == 32 {
      let denom = Double(Int32.max)
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
        let samples = data.assumingMemoryBound(to: Int32.self)
        for i in 0..<sampleCount {
          let sample = samples[i]
          let value =
            sample == Int32.min ? 1.0 : (Double(abs(Int64(sample))) / denom)
          if value > peak { peak = value }
        }
      }
    } else {
      return nil
    }

    let clampedPeak = max(0.0, min(1.0, peak))
    return (linear: clampedPeak, dbfs: dbfs(for: clampedPeak))
  }
}

final class MicrophoneLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let sessionQueue = DispatchQueue(label: "com.clingfy.mic.monitor.session")
  private let outputQueue = DispatchQueue(label: "com.clingfy.mic.monitor.output")

  private var session: AVCaptureSession?
  private var currentDeviceID: String?
  private var smoothedLinear: Double = 0.0
  private var lastEmitAt: CFTimeInterval = 0.0
  private let emitIntervalSeconds: Double = 1.0 / 15.0

  var onLevel: ((MicrophoneLevelSample) -> Void)?

  func start(deviceID: String?, onLevel: @escaping (MicrophoneLevelSample) -> Void) {
    self.onLevel = onLevel
    guard let trimmed = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      stop(emitZero: true)
      return
    }

    sessionQueue.async { [weak self] in
      self?._start(deviceID: trimmed)
    }
  }

  func stop(emitZero: Bool = false) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self._stopSessionLocked()
      if emitZero {
        DispatchQueue.main.async {
          self.onLevel?(MicrophoneLevelSample(linear: 0.0, dbfs: -160.0))
        }
      }
    }
  }

  private func _start(deviceID: String) {
    if currentDeviceID == deviceID, let session, session.isRunning {
      return
    }

    _stopSessionLocked()

    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      NativeLogger.w("MicMonitor", "Microphone permission not granted; level monitor disabled")
      DispatchQueue.main.async {
        self.onLevel?(MicrophoneLevelSample(linear: 0.0, dbfs: -160.0))
      }
      return
    }

    guard let device = AVCaptureDevice(uniqueID: deviceID) else {
      NativeLogger.w(
        "MicMonitor",
        "Selected microphone not found for monitor",
        context: ["deviceID": deviceID]
      )
      DispatchQueue.main.async {
        self.onLevel?(MicrophoneLevelSample(linear: 0.0, dbfs: -160.0))
      }
      return
    }

    let session = AVCaptureSession()
    session.beginConfiguration()

    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        NativeLogger.w("MicMonitor", "Cannot add monitor audio input")
        return
      }
      session.addInput(input)
    } catch {
      session.commitConfiguration()
      NativeLogger.e(
        "MicMonitor", "Failed to create monitor audio input", context: ["error": "\(error)"])
      return
    }

    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: outputQueue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      NativeLogger.w("MicMonitor", "Cannot add monitor audio output")
      return
    }
    session.addOutput(output)
    session.commitConfiguration()

    outputQueue.async { [weak self] in
      self?.smoothedLinear = 0.0
      self?.lastEmitAt = 0.0
    }

    session.startRunning()
    self.session = session
    self.currentDeviceID = deviceID
    NativeLogger.d(
      "MicMonitor", "Microphone level monitor started", context: ["deviceID": deviceID])
  }

  private func _stopSessionLocked() {
    if let session {
      for output in session.outputs {
        if let audioOutput = output as? AVCaptureAudioDataOutput {
          audioOutput.setSampleBufferDelegate(nil, queue: nil)
        }
      }
      if session.isRunning {
        session.stopRunning()
      }
      self.session = nil
    }
    self.currentDeviceID = nil
    outputQueue.async { [weak self] in
      self?.smoothedLinear = 0.0
      self?.lastEmitAt = 0.0
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let estimate = AudioLevelEstimator.estimatePeak(sampleBuffer: sampleBuffer) else {
      return
    }

    let alpha = estimate.linear >= smoothedLinear ? 0.35 : 0.18
    smoothedLinear = smoothedLinear * (1.0 - alpha) + estimate.linear * alpha

    let now = CFAbsoluteTimeGetCurrent()
    if now - lastEmitAt < emitIntervalSeconds { return }
    lastEmitAt = now

    let sample = MicrophoneLevelSample(
      linear: smoothedLinear,
      dbfs: AudioLevelEstimator.dbfs(for: smoothedLinear)
    )

    DispatchQueue.main.async { [weak self] in
      self?.onLevel?(sample)
    }
  }
}

private struct ExportFormatInfo {
  let ext: String
  let avFileType: AVFileType?  // nil for formats not handled by AVAssetExportSession (gif)
}

struct RecordingFileSession {
  let finalRawURL: URL
  let inProgressRawURL: URL
}

struct CaptureDestinationDiagnostics {
  static func url(for activeSession: RecordingFileSession?) -> URL {
    activeSession?.inProgressRawURL ?? AppPaths.tempRoot()
  }
}

struct RecordingArtifactPromotionPlan {
  let sourceRawURL: URL
  let finalRawURL: URL

  static func make(
    session: RecordingFileSession,
    recordedRawURL: URL,
    fileExists: (URL) -> Bool
  ) -> RecordingArtifactPromotionPlan {
    let sourceRawURL =
      fileExists(session.inProgressRawURL) ? session.inProgressRawURL : recordedRawURL
    return RecordingArtifactPromotionPlan(
      sourceRawURL: sourceRawURL,
      finalRawURL: session.finalRawURL
    )
  }
}

protocol OverlayManaging: AnyObject {
  var overlayEnabledByUser: Bool { get set }
  var overlayLinkedToRecording: Bool { get set }
  var preferredOverlaySize: Double { get set }
  func showIfNeeded(isRecording: Bool)
  func hide()
}

protocol CursorHighlighting: AnyObject {
  var enabledByUser: Bool { get set }
  var linkedToRecording: Bool { get set }
  func update(isRecording: Bool)
}

protocol RecordingIndicatorManaging: AnyObject {
  var enabledByUser: Bool { get set }
  var pinned: Bool { get set }
  func update(isRecording: Bool)
}

@MainActor
final class ScreenRecorderFacade: NSObject {
  // services
  private let prefs = PreferencesStore()
  private let saveFolder = SaveFolderStore()
  private let displaySvc = DisplayService()
  private let exporter = LetterboxExporter()
  private var captureFPS: Int = 30
  private let defaultZoomFollowStrength: CGFloat = 0.15
  private let camera = CameraOverlay()
  private let cursor = CursorHighlighter()
  private let indicator = RecordingIndicator()
  private let recordingStore = RecordingStore()
  private let micLevelMonitor = MicrophoneLevelMonitor()

  private var capture: CaptureBackend = CaptureBackendAVFoundation()

  // Metadata for current recording session (written on start, updated on finish)
  private var pendingMetadata: RecordingMetadata?
  private var currentRawURL: URL?
  private var activeRecordingFileSession: RecordingFileSession?

  // state
  private var state: RecorderState = .idle
  private var startResult: FlutterResult?
  private var stopResult: FlutterResult?
  private var pendingStop: Bool = false
  private var recordingStartedAt: Date?
  private var selectedDisplayID: CGDirectDisplayID?
  private var selectedAppWindowID: CGWindowID?
  private var followMouseMonitor: Any?
  private var followCurrentDisplay: CGDirectDisplayID?
  private var currentCaptureDisplayID: CGDirectDisplayID?
  private var lastOverlayWindowID: CGWindowID?
  private var overlayUpdateDeduper = OverlayUpdateDeduper()
  private var sessionDisableMicrophone = false
  private var sessionDisableCameraOverlay = false
  private var sessionDisableCursorHighlight = false
  private var activeRecordingWorkflowSessionId: String?

  // events out
  var onDevicesChanged: (() -> Void)?
  var onVideoDevicesChanged: (() -> Void)?
  var onIndicatorStopTapped: (() -> Void)?
  var onRecordingStateChanged: ((Bool) -> Void)?
  var onRecordingStarted: ((String) -> Void)?
  var onRecordingFinalized: ((String, String) -> Void)?
  var onRecordingFailed: (([String: Any]) -> Void)?
  var onAreaSelectionCleared: (() -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?
  var onCameraOverlayMoved: (([String: Any]) -> Void)?

  var isRecording: Bool { state == .recording }

  override init() {
    super.init()
    if let storedDisplay = prefs.selectedDisplayId {
      selectedDisplayID = CGDirectDisplayID(storedDisplay)
    }
    if let storedWindow = prefs.selectedAppWindowId {
      selectedAppWindowID = CGWindowID(storedWindow)
    }
    observeDevices()
    camera.onMovedNormalized = { [weak self] normalizedX, normalizedY in
      self?.onCameraOverlayMoved?(
        ["normalizedX": normalizedX, "normalizedY": normalizedY]
      )
    }

    setCaptureBackend(CaptureBackendAVFoundation())
    refreshMicrophoneLevelMonitoring(resetMeter: true)

    // Scan internal workspace on startup for diagnostics
    scanInternalWorkspaceOnStartup()
    cleanupStaleInProgressRecordingsOnStartup()
  }

  /// Scans the internal recordings workspace on startup for diagnostics.
  private func scanInternalWorkspaceOnStartup() {
    // Run on background thread to avoid blocking startup
    DispatchQueue.global(qos: .utility).async { [recordingStore] in
      recordingStore.logWorkspaceStats()
    }
  }

  /// Best-effort cleanup for stale crash leftovers in the temp recording workspace.
  private func cleanupStaleInProgressRecordingsOnStartup() {
    DispatchQueue.global(qos: .utility).async {
      let fm = FileManager.default
      let tempRoot = AppPaths.tempRoot()
      guard
        let files = try? fm.contentsOfDirectory(
          at: tempRoot, includingPropertiesForKeys: [.contentModificationDateKey],
          options: [.skipsHiddenFiles])
      else { return }

      let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
      var removedCount = 0

      for fileURL in files {
        guard fileURL.lastPathComponent.contains(".inprogress.") else { continue }

        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values?.contentModificationDate ?? .distantPast
        guard modifiedAt < cutoff else { continue }

        do {
          try fm.removeItem(at: fileURL)
          removedCount += 1
        } catch {
          NativeLogger.w(
            "Facade", "Failed removing stale in-progress file",
            context: ["path": fileURL.lastPathComponent, "error": error.localizedDescription])
        }
      }

      if removedCount > 0 {
        NativeLogger.i(
          "Facade", "Removed stale in-progress files on startup",
          context: ["count": removedCount, "tempRoot": tempRoot.path])
      }
    }
  }

  // MARK: method-channel facing API
  func setCaptureFrameRate(_ fps: Int) {
    self.captureFPS = fps
  }

  func getCaptureDiagnostics(result: @escaping FlutterResult) {
    var payload: [String: Any] = [
      "backend": currentBackendName(),
      "captureFps": captureFPS,
    ]
    if let bytes = availableDiskSpaceBytes(at: currentCaptureDestinationURL()) {
      payload["captureDestinationFreeBytes"] = bytes
    }
    if let bytes = availableDiskSpaceBytes(at: AppPaths.recordingsRoot()) {
      payload["recordingsFreeBytes"] = bytes
    }
    if let bytes = availableDiskSpaceBytes(at: resolveSaveFolderURL()) {
      payload["saveFolderFreeBytes"] = bytes
    }
    result(payload)
  }

  func startRecording(args: [String: Any]?, result: @escaping FlutterResult) {
    guard state == .idle else {
      if let path = currentRawURL?.path ?? capture.currentOutputURL?.path {
        result(path)
      } else {
        result(flutterError(NativeErrorCode.alreadyRecording, ""))
      }
      return
    }
    startResult = result
    state = .starting
    stateAsStr()
    refreshMicrophoneLevelMonitoring(resetMeter: true)
    activeRecordingWorkflowSessionId = args?["sessionId"] as? String
    sessionDisableMicrophone = args?["disableMicrophone"] as? Bool ?? false
    sessionDisableCameraOverlay = args?["disableCameraOverlay"] as? Bool ?? false
    sessionDisableCursorHighlight = args?["disableCursorHighlight"] as? Bool ?? false

    // macOS screen-recording permission
    if #available(macOS 10.15, *), !CGPreflightScreenCaptureAccess() {
      _ = CGRequestScreenCaptureAccess()
      finishStartWithError(
        flutterError(NativeErrorCode.screenRecordingPermission, ""))
      return
    }

    let captureTarget: CaptureTarget
    do {
      captureTarget = try resolveCaptureTarget()
    } catch CaptureTargetError.noWindowSelected {
      finishStartWithError(
        flutterError(NativeErrorCode.noWindowSelected, ""))
      return
    } catch CaptureTargetError.windowUnavailable {
      finishStartWithError(
        flutterError(NativeErrorCode.windowNotAvailable, ""))
      return
    } catch CaptureTargetError.noAreaSelected {
      finishStartWithError(
        flutterError(NativeErrorCode.noAreaSelected, ""))
      return
    } catch {
      finishStartWithError(
        flutterError(NativeErrorCode.targetError, ""))
      return
    }

    // Use internal workspace for raw recordings (not user-facing saveFolder)
    let workspaceDir = AppPaths.recordingsRoot()

    do {
      try FileManager.default.createDirectory(
        at: workspaceDir, withIntermediateDirectories: true)

      // Hide preview before starting recording
      AreaPreviewOverlay.hide()

      let target = CaptureTarget(
        mode: prefs.displayMode,
        displayID: captureTarget.displayID,
        cropRect: captureTarget.cropRect,
        windowID: (prefs.displayMode == .singleAppWindow ? selectedAppWindowID : nil)
      )

      let frameRate = args?["frameRate"] as? Int ?? 60
      let systemAudioEnabled = args?["systemAudioEnabled"] as? Bool ?? false

      if !sessionDisableMicrophone,
        let audioDeviceId = prefs.audioDeviceId,
        !audioDeviceId.isEmpty,
        audioDeviceId != "__none__",
        AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
      {
        finishStartWithError(
          flutterError(NativeErrorCode.microphonePermissionRequired, ""))
        return
      }

      if effectiveCursorEnabledForRecording && prefs.cursorLinked && !ensureAccessibilityAllowed(prompt: false)
      {
        finishStartWithError(
          flutterError(NativeErrorCode.accessibilityPermissionRequired, ""))
        return
      }

      // Prepare metadata before recording starts
      pendingMetadata = RecordingMetadata.create(
        displayMode: prefs.displayMode,
        displayID: captureTarget.displayID,
        cropRect: captureTarget.cropRect,
        frameRate: frameRate,
        quality: prefs.recordingQuality,
        cursorEnabled: effectiveCursorEnabledForRecording,
        cursorLinked: prefs.cursorLinked,
        overlayEnabled: effectiveOverlayEnabledForRecording,
        windowID: (prefs.displayMode == .singleAppWindow ? selectedAppWindowID : nil),
        excludedRecorderApp: prefs.excludeRecorderApp
      )

      activeRecordingFileSession = nil
      currentRawURL = nil

      let session = try makeRecordingFileSession(in: workspaceDir)
      try preflightCaptureDestination(session.inProgressRawURL)
      activeRecordingFileSession = session
      currentRawURL = session.finalRawURL

      NativeLogger.d(
        "Facade", "Prepared recording file session",
        context: [
          "tempRaw": session.inProgressRawURL.lastPathComponent,
          "finalRaw": session.finalRawURL.lastPathComponent,
        ])

      let outputURL: () throws -> URL = {
        session.inProgressRawURL
      }

      // Start recording
      self.currentCaptureDisplayID = target.displayID
      logOverlay(
        "startRecording before prepareCameraOverlayForRecordingStart",
        [
          "target.displayID": String(target.displayID),
          "displayMode": "\(prefs.displayMode)",
        ])

      let needsOverlay = self.effectiveOverlayEnabledForRecording && self.prefs.overlayLinked
      if needsOverlay {
        self.ensureCameraPermission {
          self.logOverlay("camera permission OK (startRecording)")
          self.prepareCameraOverlayForRecordingStart(targetDisplayID: target.displayID) {
            overlayID in
            self.startCapture(
              target: target, frameRate: frameRate, outputURL: outputURL, overlayID: overlayID,
              systemAudioEnabled: systemAudioEnabled)
          }
        } denied: { err in
          self.logOverlay(
            "camera permission DENIED (startRecording), failing requested overlay start",
            [
              "err": err.code
            ])
          self.finishStartWithError(err)
        }
      } else {
        self.prepareCameraOverlayForRecordingStart(targetDisplayID: target.displayID) { overlayID in
          self.startCapture(
            target: target, frameRate: frameRate, outputURL: outputURL, overlayID: overlayID,
            systemAudioEnabled: systemAudioEnabled)
        }
      }
    } catch let err as FlutterError {
      finishStartWithError(err)
    } catch {
      finishStartWithError(flutterError(NativeErrorCode.outputUrlError, error.localizedDescription))
    }
  }
  private func prepareCameraOverlayForRecordingStart(
    targetDisplayID: CGDirectDisplayID,
    completion: @escaping (CGWindowID?) -> Void
  ) {
    logOverlay(
      "prepareCameraOverlayForRecordingStart ENTER",
      [
        "targetDisplayID": String(targetDisplayID)
      ])

    // Only for whileRecording (linked) AND enabled
    guard effectiveOverlayEnabledForRecording, prefs.overlayLinked else {
      logOverlay("prepareCameraOverlayForRecordingStart SKIP (guard failed)")
      completion(nil)
      return
    }

    // If permission is missing, show() often fails -> overlayID=nil
    let auth = AVCaptureDevice.authorizationStatus(for: .video)
    logOverlay("camera auth status before show", ["auth": "\(auth)"])

    camera.setDevice(id: prefs.videoDeviceId)
    camera.targetDisplayID = targetDisplayID
    camera.position = prefs.overlayPosition

    camera.updateStyle(
      shape: prefs.overlayShape,
      shadow: prefs.overlayShadow,
      border: prefs.overlayBorder,
      roundness: prefs.overlayRoundness
    )
    camera.updateOpacity(prefs.overlayOpacity)
    camera.updateMirror(isMirrored: prefs.overlayMirror)
    camera.setRecordingHighlight(enabled: false)

    logOverlay(
      "calling camera.show (whileRecording)",
      [
        "size": prefs.overlaySize,
        "position": prefs.overlayPosition,
      ])

    camera.show(size: prefs.overlaySize) { [weak self] err in
      guard let self else { return }

      if let err = err {
        self.logOverlay("camera.show FAILED", ["error": "\(err)"])
        self.camera.hide()
        completion(nil)
        return
      }

      self.logOverlay(
        "camera.show OK",
        [
          "overlayWindowID_now": self.camera.overlayWindowID.map { String($0) } ?? "nil"
        ])
      let id = self.camera.overlayWindowID
      self.lastOverlayWindowID = id
      completion(id)
    }
  }
  private func startCapture(
    target: CaptureTarget,
    frameRate: Int,
    outputURL: @escaping () throws -> URL,
    overlayID: CGWindowID?,
    systemAudioEnabled: Bool
  ) {
    logOverlay(
      "startCapture()",
      [
        "overlayID_param": overlayID.map { String($0) } ?? "nil",
        "camera.overlayWindowID": camera.overlayWindowID.map { String($0) } ?? "nil",
        "prefs.excludeRecorderApp": "\(prefs.excludeRecorderApp)",
        "systemAudioEnabled": systemAudioEnabled,
        "sessionDisableMicrophone": "\(sessionDisableMicrophone)",
        "sessionDisableCameraOverlay": "\(sessionDisableCameraOverlay)",
        "sessionDisableCursorHighlight": "\(sessionDisableCursorHighlight)",
      ])

    // If caller didn't pass overlayID (e.g. alwaysOn), use current overlay window if visible
    let effectiveOverlayID: CGWindowID? = {
      if let overlayID { return overlayID }
      guard effectiveOverlayEnabledForRecording, camera.isShowing else { return nil }
      return camera.overlayWindowID
    }()

    logOverlay(
      "startCapture()", ["effectiveOverlayID": effectiveOverlayID.map { String($0) } ?? "nil"])

    let cfg = CaptureStartConfig(
      target: target,
      quality: .native,
      frameRate: frameRate,
      includeAudioDevice: self.resolveAudioDevice(disableMicrophone: sessionDisableMicrophone),
      includeSystemAudio: systemAudioEnabled,
      makeOutputURL: outputURL,
      excludeRecorderApp: self.prefs.excludeRecorderApp,
      cameraOverlayWindowID: effectiveOverlayID,
      excludeMicFromSystemAudio: self.prefs.excludeMicFromSystemAudio
    )

    let backend = CaptureBackendFactory.make(for: target)
    self.setCaptureBackend(backend)
    self.capture.start(config: cfg)
  }

  func stopRecording(result: @escaping FlutterResult) {
    switch state {
    case .idle:
      result(flutterError(NativeErrorCode.notRecording, ""))
    case .starting:
      pendingStop = true
      stopResult = result
    case .recording:
      stopResult = result
      state = .stopping
      stateAsStr()
      indicator.setState(
        .stopping,
        pinned: prefs.indicatorPinned,
        onStopTapped: nil,
        elapsedProvider: { [weak self] in self?.formattedElapsed() ?? "00:00:00" }
      )
      capture.stop()
    case .stopping:
      result(nil)
    }
  }

  // === the rest simply delegate to services/modules, mirroring our old methods ===
  func getAudioSources(result: @escaping FlutterResult) {
    let devs = AVCaptureDevice.devices(for: .audio).map {
      ["id": $0.uniqueID, "name": $0.localizedName]
    }
    result(devs)
  }
  func setAudioSource(id: String?, result: @escaping FlutterResult) {
    if let id, !id.isEmpty && id != "__none__" {
      guard AVCaptureDevice(uniqueID: id) != nil else {
        result(flutterError(NativeErrorCode.unknownAudioDevice, ""))
        return
      }
      prefs.audioDeviceId = id
      refreshMicrophoneLevelMonitoring(resetMeter: false)
      result(id)
    } else {
      prefs.audioDeviceId = nil
      refreshMicrophoneLevelMonitoring(resetMeter: true)
      result(nil)
    }
  }

  func getVideoSources(result: @escaping FlutterResult) {
    let devs = AVCaptureDevice.devices(for: .video).map {
      ["id": $0.uniqueID, "name": $0.localizedName]
    }
    result(devs)
  }
  func setVideoSource(id: String?, result: @escaping FlutterResult) {
    logOverlay("setVideoSource called", ["idArg": id ?? "nil"])
    prefs.videoDeviceId = id
    camera.setDevice(id: id)
    result(id)
  }

  func showCameraOverlay(size: Double?, result: @escaping FlutterResult) {
    logOverlay("showCameraOverlay called", ["sizeArg": size ?? -1])
    ensureCameraPermission {
      self.prefs.overlayEnabled = true
      let targetSize = max(120.0, size ?? self.prefs.overlaySize)
      self.prefs.overlaySize = targetSize

      // Apply style first
      self.camera.updateStyle(
        shape: self.prefs.overlayShape, shadow: self.prefs.overlayShadow,
        border: self.prefs.overlayBorder, roundness: self.prefs.overlayRoundness)

      if self.camera.isShowing {
        // `camera.show` handles idempotent updates while the overlay is visible.
        self.camera.show(size: targetSize) { error in
          if let error = error {
            result(error)
          } else {
            self.updateOverlayVisibility()
            result(nil)
          }
        }
      } else {
        self.camera.preferredSize = targetSize
        self.updateOverlayVisibility()
        result(nil)
      }
    } denied: { err in
      result(err)
    }
  }

  func setCameraOverlaySize(size: Double?, result: @escaping FlutterResult) {
    guard let size = size else {
      result(nil)
      return
    }
    self.prefs.overlaySize = max(120.0, size)
    if self.camera.isShowing {
      self.camera.resize(size: self.prefs.overlaySize)
    }
    result(nil)
  }
  func hideCameraOverlay(result: @escaping FlutterResult) {
    logOverlay("hideCameraOverlay called")
    prefs.overlayEnabled = false
    updateOverlayVisibility()
    result(nil)
  }
  func setCameraOverlayFrame(
    x: Double, y: Double, width: Double, height: Double, result: @escaping FlutterResult
  ) {
    camera.setFrame(x: x, y: y, width: width, height: height)
    result(nil)
  }

  func setCameraOverlayShape(shapeId: Int, result: @escaping FlutterResult) {
    let shape =
      CameraOverlayShapeID(rawValue: shapeId)
      ?? CameraOverlayShapeID.defaultValue
    prefs.overlayShape = shape
    camera.updateStyle(
      shape: shape, shadow: prefs.overlayShadow, border: prefs.overlayBorder,
      roundness: prefs.overlayRoundness)
    result(nil)
  }

  func setCameraOverlayShadow(shadow: Int, result: @escaping FlutterResult) {
    prefs.overlayShadow = shadow
    camera.updateStyle(
      shape: prefs.overlayShape, shadow: shadow, border: prefs.overlayBorder,
      roundness: prefs.overlayRoundness)
    result(nil)
  }

  func setCameraOverlayBorder(border: Int, result: @escaping FlutterResult) {
    prefs.overlayBorder = border
    camera.updateStyle(
      shape: prefs.overlayShape, shadow: prefs.overlayShadow, border: prefs.overlayBorder,
      roundness: prefs.overlayRoundness)
    result(nil)
  }

  func setCameraOverlayRoundness(roundness: Double, result: @escaping FlutterResult) {
    prefs.overlayRoundness = roundness
    camera.updateStyle(
      shape: prefs.overlayShape, shadow: prefs.overlayShadow, border: prefs.overlayBorder,
      roundness: roundness)
    result(nil)
  }

  func setCameraOverlayOpacity(opacity: Double, result: @escaping FlutterResult) {
    prefs.overlayOpacity = opacity
    camera.updateOpacity(opacity)
    result(nil)
  }

  func setOverlayMirror(_ mirrored: Bool, result: @escaping FlutterResult) {
    prefs.overlayMirror = mirrored
    camera.updateMirror(isMirrored: mirrored)
    result(nil)
  }

  func setCameraOverlayHighlight(enabled: Bool, result: @escaping FlutterResult) {
    prefs.overlayHighlight = enabled
    camera.setRecordingHighlight(enabled: enabled)
    result(nil)
  }

  func setCameraOverlayHighlightStrength(strength: Double, result: @escaping FlutterResult) {
    camera.setRecordingHighlightStrength(CGFloat(strength))
    result(nil)
  }

  func setChromaKeyEnabled(_ enabled: Bool) {
    camera.setChromaKeyEnabled(enabled)
  }

  func setChromaKeyStrength(_ strength: Double) {
    camera.setChromaKeyStrength(strength)
  }

  func setCameraOverlayPosition(position: Int, result: @escaping FlutterResult) {
    prefs.overlayPosition = position
    camera.updatePosition(position: position)
    result(nil)
  }

  func setCameraOverlayCustomPosition(
    normalizedX: Double,
    normalizedY: Double,
    result: @escaping FlutterResult
  ) {
    camera.setCustomNormalizedCenter(
      x: CGFloat(normalizedX),
      y: CGFloat(normalizedY)
    )
    result(nil)
  }

  func setCameraOverlayBorderWidth(width: Double, result: @escaping FlutterResult) {
    camera.setBorderWidth(CGFloat(width))
    result(nil)
  }

  func setCameraOverlayBorderColor(_ color: NSColor, result: @escaping FlutterResult) {
    camera.setBorderColor(color)
    result(nil)
  }

  func setChromaKeyColor(_ color: NSColor, result: @escaping FlutterResult) {
    camera.setChromaKeyColor(color)
    result(nil)
  }
  func setOverlayEnabled(enabled: Bool, result: @escaping FlutterResult) {
    logOverlay("setOverlayEnabled called", ["enabledArg": enabled])
    if enabled {
      ensureCameraPermission {
        self.prefs.overlayEnabled = true
        self.updateOverlayVisibility()
        result(nil)
      } denied: { err in
        result(err)
      }
    } else {
      prefs.overlayEnabled = false
      updateOverlayVisibility()
      result(nil)
    }
  }
  func setOverlayLinkedToRecording(linked: Bool, result: @escaping FlutterResult) {
    logOverlay("setOverlayLinkedToRecording called", ["linkedArg": linked])
    prefs.overlayLinked = linked
    updateOverlayVisibility()
    result(nil)
  }

  // Tracks whether the accessibility prompt has already been shown.
  private let kAXPrompted = "axPromptedOnce"

  func setCursorHighlightEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    if enabled && !AXIsProcessTrusted() {
      _ = ensureAccessibilityAllowedAndGuideUser()
      result(
        FlutterError(
          code: "ACCESSIBILITY_PERMISSION_REQUIRED",
          message: "",
          details: nil))
      return
    }
    prefs.cursorEnabled = enabled
    updateCursorVisibility()
    result(nil)
  }

  func setCursorHighlightLinkedToRecording(linked: Bool, result: @escaping FlutterResult) {
    prefs.cursorLinked = linked
    updateCursorVisibility()
    result(nil)
  }

  func relaunchApp() {
    let url = Bundle.main.bundleURL
    if #available(macOS 10.15, *) {
      let cfg = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
      }
    }

  }

  func setRecordingQuality(_ name: String?, result: @escaping FlutterResult) {
    guard let name, let q = RecordingQuality(rawValue: name) else {
      result(flutterError(NativeErrorCode.badQuality, ""))
      return
    }
    prefs.recordingQuality = q
    result(nil)
  }

  func setExcludeRecorderApp(_ exclude: Bool, result: @escaping FlutterResult) {
    prefs.excludeRecorderApp = exclude
    NativeLogger.i("Facade", "Set excludeRecorderApp", context: ["exclude": exclude])
    result(nil)
  }

  func getExcludeRecorderApp(result: @escaping FlutterResult) {
    result(prefs.excludeRecorderApp)
  }

  func setExcludeMicFromSystemAudio(_ exclude: Bool, result: @escaping FlutterResult) {
    prefs.excludeMicFromSystemAudio = exclude
    NativeLogger.i("Facade", "Set excludeMicFromSystemAudio", context: ["exclude": exclude])
    result(nil)
  }

  func getExcludeMicFromSystemAudio(result: @escaping FlutterResult) {
    result(prefs.excludeMicFromSystemAudio)
  }

  func getDisplays(result: @escaping FlutterResult) { result(displaySvc.allDisplays()) }
  func setDisplay(id: NSNumber?, result: @escaping FlutterResult) {
    prefs.selectedDisplayId = id == nil ? nil : Int(id!.uint32Value)
    selectedDisplayID = id == nil ? nil : CGDirectDisplayID(id!.uint32Value)
    result(nil)
  }
  func getAppWindows(result: @escaping FlutterResult) { result(displaySvc.appWindows()) }

  func setAppWindow(windowId: NSNumber?, result: @escaping FlutterResult) {
    if let windowId {
      prefs.selectedAppWindowId = Int(windowId.uint32Value)
      selectedAppWindowID = CGWindowID(windowId.uint32Value)
    } else {
      prefs.selectedAppWindowId = nil
      selectedAppWindowID = nil
    }
    result(nil)
  }

  func setDisplayTargetMode(modeRaw: NSNumber, result: @escaping FlutterResult) {
    let newMode = DisplayTargetMode(rawValue: modeRaw.intValue) ?? .explicitID

    prefs.displayMode = newMode
    result(nil)
  }

  func pickAreaRecordingRegion(result: @escaping FlutterResult) {
    let targetDisplay =
      selectedDisplayID ?? displaySvc.displayIDUnderMouse() ?? CGMainDisplayID()
    AreaSelectionOverlay.show(onDisplay: targetDisplay) { [weak self] chosen in
      guard let self = self else { return }
      if let chosen = chosen {
        self.prefs.areaDisplayId = Int(chosen.displayID)
        self.prefs.areaRect = chosen.rect

        // Short-lived border reveal after selection is completed.
        AreaPreviewOverlay.show(
          displayID: chosen.displayID,
          rect: chosen.rect,
          autoHideAfter: 1.0
        )

        result([
          "displayId": chosen.displayID,
          "x": chosen.rect.origin.x,
          "y": chosen.rect.origin.y,
          "width": chosen.rect.size.width,
          "height": chosen.rect.size.height,
        ])
      } else {
        result(nil)
      }
    }
  }

  func revealAreaRecordingRegion(result: @escaping FlutterResult) {
    guard let rect = prefs.areaRect, let displayID = prefs.areaDisplayId else {
      result(nil)
      return
    }
    AreaPreviewOverlay.show(
      displayID: CGDirectDisplayID(displayID),
      rect: rect,
      autoHideAfter: 1.0
    )
    result(nil)
  }

  func clearAreaRecordingSelection(result: FlutterResult? = nil) {
    prefs.areaDisplayId = nil
    prefs.areaRect = nil
    AreaPreviewOverlay.hide()
    onAreaSelectionCleared?()
    result?(nil)
  }

  func setFileNameTemplate(_ tpl: String?, result: @escaping FlutterResult) {
    let trimmed = (tpl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    prefs.fileTemplate = trimmed.isEmpty ? "{appname}-{date}-{time}" : trimmed
    result(nil)
  }

  func getSaveFolderPath() -> String { saveFolder.resolveFolderURL().path }
  func persistSaveFolderURL(_ url: URL) throws { try saveFolder.persist(url) }
  func resetSaveFolder() { UserDefaults.standard.removeObject(forKey: PrefKey.saveFolderBookmark) }
  func openSaveFolder() { NSWorkspace.shared.open(saveFolder.resolveFolderURL()) }
  func revealFile(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  func setRecordingIndicatorPinned(_ pinned: Bool, result: @escaping FlutterResult) {
    prefs.indicatorPinned = pinned
    indicator.setState(
      state == .recording ? .recording : (state == .stopping ? .stopping : .hidden),
      pinned: pinned,
      onStopTapped: { [weak self] in self?.onIndicatorStopTapped?() },
      elapsedProvider: { [weak self] in self?.formattedElapsed() ?? "00:00:00" }
    )
    result(nil)
  }

  // MARK: helpers
  private func resolveTargetSize(
    sourceSize: CGSize,
    layout: String,
    resolution: String
  ) -> CGSize {
    // 1. Resolve Aspect Ratio from Layout Preset
    let aspect: CGFloat
    switch layout {
    case "classic43": aspect = 4.0 / 3.0
    case "square11": aspect = 1.0
    case "youtube169": aspect = 16.0 / 9.0
    case "reel916": aspect = 9.0 / 16.0
    default: aspect = sourceSize.width / max(sourceSize.height, 1)
    }

    // 2. Resolve Resolution (Short Side)
    let shortSide: CGFloat
    switch resolution {
    case "p1080": shortSide = 1080
    case "p1440": shortSide = 1440
    case "p2160": shortSide = 2160
    case "p4320": shortSide = 4320
    default:
      // Auto: Use source pixels but respect the aspect ratio we just chose.
      // This means we might grow one dimension to fit the aspect.
      return sourceSize
    }

    // 3. Compute final size based on shortSide and aspect
    // If aspect > 1 (horizontal), shortSide is height.
    // If aspect < 1 (vertical), shortSide is width.
    if aspect >= 1.0 {
      // Horizontal or Square
      return CGSize(width: shortSide * aspect, height: shortSide)
    } else {
      // Vertical
      return CGSize(width: shortSide, height: shortSide / aspect)
    }
  }

  func processVideo(
    source: String,
    layout: String,
    resolution: String,
    fit: String,
    padding: Double,
    cornerRadius: Double,
    backgroundColor: Int?,
    backgroundImagePath: String?,
    cursorSize: Double,
    zoomFactor: Double,
    showCursor: Bool,
    format: String,
    codec: String,
    bitrate: String,
    audioGainDb: Double,
    audioVolumePercent: Double,
    zoomSegments: [ZoomTimelineSegment]?,
    result: @escaping FlutterResult
  ) {
    let inputURL = URL(fileURLWithPath: source)
    let asset = AVAsset(url: inputURL)

    func orientedSize(_ track: AVAssetTrack) -> CGSize {
      let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
      return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    let srcSize: CGSize = {
      if let track = asset.tracks(withMediaType: .video).first {
        return orientedSize(track)
      }
      return CGSize(width: 1920, height: 1080)
    }()

    let targetSize = resolveTargetSize(sourceSize: srcSize, layout: layout, resolution: resolution)

    let clampedGainDb = max(0, min(24, audioGainDb))
    let clampedVolumePercent = max(0, min(100, audioVolumePercent))

    var params = CompositionParams(
      targetSize: targetSize,
      padding: padding,
      cornerRadius: cornerRadius,
      backgroundColor: backgroundColor,
      backgroundImagePath: backgroundImagePath,
      cursorSize: cursorSize,
      showCursor: showCursor,
      zoomEnabled: true,
      zoomFactor: CGFloat(zoomFactor),
      followStrength: defaultZoomFollowStrength,
      fpsHint: 60,
      fitMode: fit,
      audioGainDb: clampedGainDb,
      audioVolumePercent: clampedVolumePercent
    )
    params.zoomSegments = zoomSegments

    NativeLogger.i(
      "Facade", "processVideo called (New Architecture)",
      context: [
        "source": source,
        "layout": layout,
        "resolution": resolution,
        "fit": fit,
        "targetSize": "\(targetSize.width)x\(targetSize.height)",
        "zoomSegments": zoomSegments.map { "\($0.count)" } ?? "nil",
      ])

    DispatchQueue.main.async {
      pendingPreviewParams = params

      if let view = inlinePreviewViewInstance {
        view.updateComposition(params: params)
      }
    }
    result(source)
  }

  func previewSetAudioGainDb(audioGainDb: Double, result: @escaping FlutterResult) {
    previewSetAudioMix(
      sessionId: nil,
      audioGainDb: audioGainDb,
      audioVolumePercent: 100.0,
      result: result
    )
  }

  func previewSetAudioMix(
    sessionId: String?,
    audioGainDb: Double,
    audioVolumePercent: Double,
    result: @escaping FlutterResult
  ) {
    let clampedGainDb = max(0, min(24, audioGainDb))
    let clampedVolumePercent = max(0, min(100, audioVolumePercent))
    if let view = inlinePreviewViewInstance {
      if let sessionId, view.currentSessionId != sessionId {
        result(nil)
        return
      }
      view.updateAudioMixOnly(gainDb: clampedGainDb, volumePercent: clampedVolumePercent)
    } else if let sessionId,
      let request = pendingPreviewOpenRequest,
      request.sessionId != sessionId
    {
      result(nil)
      return
    }
    result(nil)
  }

  func exportVideo(
    source: String,
    layout: String,
    resolution: String,
    fit: String,
    padding: Double,
    cornerRadius: Double,
    backgroundColor: Int?,
    backgroundImagePath: String?,
    cursorSize: Double,
    zoomFactor: Double,
    showCursor: Bool,
    filename: String?,
    directoryOverride: String?,
    format: String,
    codec: String,
    bitrate: String,
    audioGainDb: Double,
    audioVolumePercent: Double,
    autoNormalizeOnExport: Bool,
    targetLoudnessDbfs: Double,
    onProgress: ((Double) -> Void)? = nil,
    result: @escaping FlutterResult
  ) {
    let inputURL = URL(fileURLWithPath: source)
    let asset = AVAsset(url: inputURL)

    func orientedSize(_ track: AVAssetTrack) -> CGSize {
      let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
      return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    let srcSize: CGSize = {
      if let track = asset.tracks(withMediaType: .video).first {
        return orientedSize(track)
      }
      return CGSize(width: 1920, height: 1080)
    }()

    let targetSize = resolveTargetSize(sourceSize: srcSize, layout: layout, resolution: resolution)

    if !FileManager.default.fileExists(atPath: inputURL.path) {
      result(
        FlutterError(
          code: "EXPORT_INPUT_MISSING",
          message: "Recording file not found. It may have been moved or deleted.",
          details: inputURL.path))
      return
    }

    let folder: URL
    if let directoryOverride = directoryOverride, !directoryOverride.isEmpty {
      folder = URL(fileURLWithPath: directoryOverride)
    } else {
      folder = saveFolder.resolveFolderURL()
    }

    let info = exportFormatInfo(format)
    let name = (filename?.isEmpty ?? true) ? "processed" : filename!
    let stem = (name as NSString).deletingPathExtension
    let finalName = "\(stem).\(info.ext)"
    var outputURL = folder.appendingPathComponent(finalName)
    var idx = 1
    while FileManager.default.fileExists(atPath: outputURL.path) {
      outputURL = folder.appendingPathComponent("\(stem) (\(idx)).\(info.ext)")
      idx += 1
    }

    // Capture self and prefs for cleanup after export
    let keepOriginals = prefs.keepOriginals
    let recordingStoreRef = recordingStore

    let clampedGainDb = max(0, min(24, audioGainDb))
    let clampedVolumePercent = max(0, min(100, audioVolumePercent))
    let clampedTargetLoudnessDbfs = max(-24.0, min(-6.0, targetLoudnessDbfs))

    exporter.export(
      inputURL: inputURL,
      target: targetSize,
      padding: padding,
      cornerRadius: cornerRadius,
      backgroundColor: backgroundColor,
      backgroundImagePath: backgroundImagePath,
      cursorSize: cursorSize,
      showCursor: showCursor,
      zoomEnabled: true,
      zoomFactor: CGFloat(zoomFactor),
      followStrength: defaultZoomFollowStrength,
      outputURL: outputURL,
      format: format,
      codec: codec,
      bitrate: bitrate,
      fitMode: fit,
      audioGainDb: clampedGainDb,
      audioVolumePercent: clampedVolumePercent,
      autoNormalizeOnExport: autoNormalizeOnExport,
      targetLoudnessDbfs: clampedTargetLoudnessDbfs,
      onProgress: onProgress,
    ) { res in
      switch res {
      case .success(let final):
        // Cleanup raw recording and sidecars after successful export
        DispatchQueue.global(qos: .utility).async {
          recordingStoreRef.cleanupAfterExport(rawURL: inputURL, keepOriginals: keepOriginals)
        }
        result(final.path)
      case .failure(let err):
        result(FlutterError(code: "EXPORT_ERROR", message: err.localizedDescription, details: nil))
      }
    }
  }

  func cancelExport() {
    exporter.cancel()
  }

  func getZoomSegments(videoPath: String, result: @escaping FlutterResult) {
    let videoURL = URL(fileURLWithPath: videoPath)
    let asset = AVAsset(url: videoURL)

    // 1. Check if asset is valid and duration is finite
    guard asset.duration.isNumeric else {
      NativeLogger.e(
        "Facade", "getZoomSegments: duration is not numeric", context: ["path": videoPath])
      result([])
      return
    }
    let durationSeconds = asset.duration.seconds

    // 2. Locate cursor sidecar
    let cursorURL = AppPaths.cursorSidecarURL(for: videoURL)

    guard FileManager.default.fileExists(atPath: cursorURL.path) else {
      NativeLogger.w(
        "Facade", "getZoomSegments: cursor.json missing", context: ["path": cursorURL.path])
      result([])
      return
    }

    // 3. Load and decode cursor recording
    do {
      let data = try Data(contentsOf: cursorURL)
      let cursorRecording = try JSONDecoder().decode(CursorRecording.self, from: data)

      // 4. Build segments
      let segments = ZoomTimelineBuilder.buildSegments(
        cursorRecording: cursorRecording,
        durationSeconds: durationSeconds
      )

      // 5. Convert to dictionaries for result
      let dicts = segments.enumerated().map { (index, segment) in
        return [
          "id": "auto_\(index)",
          "startMs": segment.startMs,
          "endMs": segment.endMs,
          "source": "auto",
        ]
      }
      result(dicts)
    } catch {
      NativeLogger.e(
        "Facade", "getZoomSegments: failed to decode cursor.json",
        context: [
          "path": cursorURL.path,
          "error": error.localizedDescription,
        ])
      result([])
    }
  }

  private func finishStartWithError(_ err: FlutterError) {
    if let sessionId = activeRecordingWorkflowSessionId {
      onRecordingFailed?([
        "type": "recordingFailed",
        "sessionId": sessionId,
        "stage": "start",
        "code": err.code,
        "error": err.message ?? "",
      ])
    }
    state = .idle
    stateAsStr()
    refreshMicrophoneLevelMonitoring(resetMeter: false)
    resetRecordingSessionSuppressions()
    activeRecordingFileSession = nil
    currentRawURL = nil
    pendingMetadata = nil
    activeRecordingWorkflowSessionId = nil
    startResult?(err)
    startResult = nil
  }
  private func formattedElapsed() -> String {
    guard let start = recordingStartedAt else { return "00:00:00" }
    let secs = max(0, Int(Date().timeIntervalSince(start)))
    let f = DateComponentsFormatter()
    f.allowedUnits = [.hour, .minute, .second]
    f.zeroFormattingBehavior = [.pad]
    return f.string(from: TimeInterval(secs)) ?? "00:00:00"
  }
  private func ensureAccessibilityAllowed(prompt: Bool) -> Bool {
    let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(opt)
  }
  private var effectiveOverlayEnabledForRecording: Bool {
    prefs.overlayEnabled && !sessionDisableCameraOverlay
  }

  private var effectiveCursorEnabledForRecording: Bool {
    prefs.cursorEnabled && !sessionDisableCursorHighlight
  }

  private func resetRecordingSessionSuppressions() {
    sessionDisableMicrophone = false
    sessionDisableCameraOverlay = false
    sessionDisableCursorHighlight = false
  }

  private func resolveAudioDevice(disableMicrophone: Bool) -> AVCaptureDevice? {
    // Audio input is optional — only use a device when the user has explicitly selected one.
    guard !disableMicrophone else { return nil }
    guard let id = prefs.audioDeviceId, !id.isEmpty, id != "__none__" else { return nil }
    return AVCaptureDevice(uniqueID: id)
  }
  private func appName() -> String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ScreenRecording")
      .replacingOccurrences(of: "[/\\\\:?%*|\"<>]+", with: "-", options: .regularExpression)
  }
  /// Generates a unique output URL for a recording in the specified folder.
  ///
  /// - Parameter folder: The destination folder for the recording file
  /// - Returns: A unique URL for the recording
  private func makeOutputURL(in folder: URL) throws -> URL {
    let df = DateFormatter()
    df.locale = .init(identifier: "en_US_POSIX")
    df.timeZone = .current
    df.dateFormat = "yyyy-MM-dd"
    let tf = DateFormatter()
    tf.locale = .init(identifier: "en_US_POSIX")
    tf.timeZone = .current
    tf.dateFormat = "HH-mm-ss"
    let now = Date()
    var name = prefs.fileTemplate
      .replacingOccurrences(of: "{appname}", with: appName())
      .replacingOccurrences(of: "{date}", with: df.string(from: now))
      .replacingOccurrences(of: "{time}", with: tf.string(from: now))
      .replacingOccurrences(of: "{quality}", with: prefs.recordingQuality.rawValue)
    if !name.lowercased().hasSuffix(".mov") { name += ".mov" }

    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension.isEmpty ? "mov" : (name as NSString).pathExtension
    var candidate = folder.appendingPathComponent("\(stem).\(ext)")
    var idx = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent(String(format: "%@-%03d.%@", stem, idx, ext))
      idx += 1
    }
    return candidate
  }

  private func makeRecordingFileSession(in finalFolder: URL) throws -> RecordingFileSession {
    let fm = FileManager.default
    let finalRawURL = try makeOutputURL(in: finalFolder)

    let tempFolder = AppPaths.tempRoot()
    try fm.createDirectory(at: tempFolder, withIntermediateDirectories: true)

    let stem = finalRawURL.deletingPathExtension().lastPathComponent
    let ext = finalRawURL.pathExtension.isEmpty ? "mov" : finalRawURL.pathExtension
    var tempRawURL = tempFolder.appendingPathComponent(
      "\(stem).\(UUID().uuidString).inprogress.\(ext)")

    while fm.fileExists(atPath: tempRawURL.path) {
      tempRawURL = tempFolder.appendingPathComponent(
        "\(stem).\(UUID().uuidString).inprogress.\(ext)")
    }

    return RecordingFileSession(finalRawURL: finalRawURL, inProgressRawURL: tempRawURL)
  }

  private func moveItemIfExists(from sourceURL: URL, to destinationURL: URL) throws {
    let fm = FileManager.default
    let src = sourceURL.standardizedFileURL
    let dst = destinationURL.standardizedFileURL

    if src.path == dst.path { return }
    guard fm.fileExists(atPath: src.path) else { return }

    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

    if fm.fileExists(atPath: dst.path) {
      try fm.removeItem(at: dst)
    }

    do {
      try fm.moveItem(at: src, to: dst)
    } catch {
      // Fallback for cross-volume moves.
      try fm.copyItem(at: src, to: dst)
      try? fm.removeItem(at: src)
    }
  }

  private func finalizeRecordingArtifactsIfNeeded(recordedRawURL: URL) throws -> URL {
    guard let session = activeRecordingFileSession else { return recordedRawURL }

    let promotionPlan = RecordingArtifactPromotionPlan.make(
      session: session,
      recordedRawURL: recordedRawURL,
      fileExists: { FileManager.default.fileExists(atPath: $0.path) }
    )

    try moveItemIfExists(from: promotionPlan.sourceRawURL, to: promotionPlan.finalRawURL)

    let tempSidecars = AppPaths.allSidecarURLs(for: promotionPlan.sourceRawURL)
    let finalSidecars = AppPaths.allSidecarURLs(for: promotionPlan.finalRawURL)
    for (src, dst) in zip(tempSidecars, finalSidecars) {
      try moveItemIfExists(from: src, to: dst)
    }

    return promotionPlan.finalRawURL
  }
  private enum CaptureTargetError: Error {
    case noWindowSelected, windowUnavailable, noAreaSelected
  }

  private func resolveCaptureTarget() throws -> CaptureTarget {
    switch prefs.displayMode {
    case .explicitID:
      return CaptureTarget(
        mode: DisplayTargetMode.explicitID,
        displayID: selectedDisplayID ?? displaySvc.displayIDForAppWindowOrMain(),
        cropRect: nil,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    case .appWindow:
      return CaptureTarget(
        mode: DisplayTargetMode.appWindow,
        displayID: displaySvc.displayIDForAppWindowOrMain(),
        cropRect: nil,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    case .mouseAtStart, .followMouse:
      return CaptureTarget(
        mode: DisplayTargetMode.mouseAtStart,
        displayID: displaySvc.displayIDUnderMouse() ?? displaySvc.displayIDForAppWindowOrMain(),
        cropRect: nil,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    case .singleAppWindow:
      guard let windowID = selectedAppWindowID else { throw CaptureTargetError.noWindowSelected }
      guard let config = displaySvc.captureTarget(forWindowID: windowID) else {
        throw CaptureTargetError.windowUnavailable
      }
      return CaptureTarget(
        mode: DisplayTargetMode.singleAppWindow,
        displayID: config.displayID,
        cropRect: config.rect,  // for cursor normalization
        windowID: windowID  // for SCK true window capture
      )
    case .areaRecording:
      guard let rect = prefs.areaRect, let displayID = prefs.areaDisplayId else {
        throw CaptureTargetError.noAreaSelected
      }
      return CaptureTarget(
        mode: DisplayTargetMode.areaRecording,
        displayID: CGDirectDisplayID(displayID),
        cropRect: rect,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    }
  }
  private func updateOverlayVisibility(
    file: String = #file,
    line: Int = #line
  ) {
    NativeLogger.d("Facade", "updateOverlayVisibility file= \(file):\(line)")
    let shouldShow =
      effectiveOverlayEnabledForRecording && (!prefs.overlayLinked || isStartingOrRecording())
    logOverlay(
      "updateOverlayVisibility ENTER",
      [
        "file": file, "line": line,
        "shouldShow": shouldShow,
        "isStartingOrRecording": isStartingOrRecording(),
      ])
    stateAsStr()

    if shouldShow {
      camera.setDevice(id: prefs.videoDeviceId)
      camera.targetDisplayID = currentCaptureDisplayID ?? selectedDisplayID
      camera.updateStyle(
        shape: prefs.overlayShape, shadow: prefs.overlayShadow, border: prefs.overlayBorder,
        roundness: prefs.overlayRoundness)

      // Keep manual drag position while already showing; preset changes are
      // pushed explicitly through setCameraOverlayPosition.
      if !camera.isShowing {
        camera.position = prefs.overlayPosition
      }
      camera.updateOpacity(prefs.overlayOpacity)
      camera.updateMirror(isMirrored: prefs.overlayMirror)
      camera.setRecordingHighlight(enabled: (state == .recording) && prefs.overlayHighlight)

      logOverlay(
        "updateOverlayVisibility -> calling camera.show",
        [
          "size": prefs.overlaySize,
          "targetDisplay": (currentCaptureDisplayID ?? selectedDisplayID).map { String($0) }
            ?? "nil",
        ])

      // CameraOverlay.show() now handles idempotency internally,
      // ensuring we only rebuild if the capture (Chroma Key or Device) changed.
      camera.show(size: prefs.overlaySize) { [weak self] _ in
        guard let self else { return }
        self.logOverlay(
          "camera.show callback in updateOverlayVisibility",
          [
            "state": "\(self.state)",
            "overlayWindowID": self.camera.overlayWindowID.map { String($0) } ?? "nil",
          ])
        if self.state == .recording {
          self.logOverlay(
            "calling capture.updateOverlay(windowID:)",
            [
              "windowID": self.camera.overlayWindowID.map { String($0) } ?? "nil",
              "backend": "\(type(of: self.capture))",
            ])
          self.lastOverlayWindowID = self.camera.overlayWindowID
          self.sendOverlayUpdateIfNeeded(self.camera.overlayWindowID)
        }
      }
    } else {
      logOverlay("updateOverlayVisibility -> hiding camera")
      camera.hide()
      if state == .recording {
        logOverlay("updateOverlayVisibility -> capture.updateOverlay(nil)")
        sendOverlayUpdateIfNeeded(nil)
      }
    }
  }

  private func sendOverlayUpdateIfNeeded(_ windowID: CGWindowID?) {
    guard overlayUpdateDeduper.shouldSend(windowID) else {
      logOverlay(
        "Skipping duplicate overlay update",
        [
          "windowID": windowID.map { String($0) } ?? "nil",
          "backend": "\(type(of: capture))",
        ])
      return
    }

    capture.updateOverlay(windowID: windowID)
  }

  private func resetOverlayUpdateDeduper() {
    overlayUpdateDeduper.reset()
  }

  private func updateCursorVisibility() {
    let shouldShow =
      prefs.cursorLinked
      ? (state == .recording && effectiveCursorEnabledForRecording)
      : effectiveCursorEnabledForRecording
    shouldShow ? cursor.start() : cursor.stop()
  }

  private func observeDevices() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(devChanged(_:)), name: AVCaptureDevice.wasConnectedNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(devChanged(_:)), name: AVCaptureDevice.wasDisconnectedNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParamsChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(workspaceWillSleep(_:)),
      name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(workspaceDidWake(_:)),
      name: NSWorkspace.didWakeNotification, object: nil)
  }
  @objc private func devChanged(_ n: Notification) {
    guard let dev = n.object as? AVCaptureDevice else { return }
    if dev.hasMediaType(.audio) {
      onDevicesChanged?()
      refreshMicrophoneLevelMonitoring(resetMeter: false)
    }
    if dev.hasMediaType(.video) { onVideoDevicesChanged?() }
  }

  @objc private func screenParamsChanged() {
    logCaptureSystemEvent("screenParametersChanged")
    if let sel = selectedDisplayID,
      !NSScreen.screens.contains(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == sel
      })
    {
      selectedDisplayID = nil
    }
    if let areaDisplayID = prefs.areaDisplayId,
      !NSScreen.screens.contains(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
          == areaDisplayID
      })
    {
      clearAreaRecordingSelection()
    }
    onDevicesChanged?()
  }

  @objc private func workspaceWillSleep(_ notification: Notification) {
    logCaptureSystemEvent("willSleep")
  }

  @objc private func workspaceDidWake(_ notification: Notification) {
    logCaptureSystemEvent("didWake")
  }

  private func logCaptureSystemEvent(_ event: String) {
    guard isStartingOrRecording() else { return }

    NativeLogger.i(
      "Facade", "Capture system event",
      context: [
        "event": event,
        "state": "\(state)",
        "backend": currentBackendName(),
        "selectedDisplayID": selectedDisplayID.map { String($0) } ?? "nil",
        "currentCaptureDisplayID": currentCaptureDisplayID.map { String($0) } ?? "nil",
        "overlayWindowID": camera.overlayWindowID.map { String($0) } ?? "nil",
      ])
  }

  private func refreshMicrophoneLevelMonitoring(resetMeter: Bool) {
    guard state == .idle else {
      micLevelMonitor.stop(emitZero: resetMeter)
      return
    }

    guard let micId = prefs.audioDeviceId, !micId.isEmpty else {
      micLevelMonitor.stop(emitZero: true)
      return
    }

    micLevelMonitor.start(deviceID: micId) { [weak self] sample in
      self?.onMicrophoneLevel?(sample)
    }
  }

  // --- Persisted Save Folder (bookmark helpers) ---
  public func resolveSaveFolderURL() -> URL {
    saveFolder.resolveFolderURL()
  }

  private func currentBackendName() -> String {
    let raw = String(describing: type(of: capture)).lowercased()
    if raw.contains("screencapturekit") || raw.contains("sck") {
      return "screencapturekit"
    }
    if raw.contains("avfoundation") {
      return "avfoundation"
    }
    return String(describing: type(of: capture))
  }

  private func currentCaptureDestinationURL() -> URL {
    CaptureDestinationDiagnostics.url(for: activeRecordingFileSession)
  }

  private func preflightCaptureDestination(_ url: URL) throws {
    let targetURL = diskSpaceLookupURL(for: url)
    let bytes = availableDiskSpaceBytes(at: url)

    NativeLogger.i(
      "Facade", "Capture destination disk preflight",
      context: [
        "path": targetURL.path,
        "availableBytes": bytes ?? -1,
      ])

    guard let bytes else { return }
    guard bytes > 0 else {
      throw flutterError(
        NativeErrorCode.outputUrlError,
        "Capture destination has no available disk space"
      )
    }
  }

  private func diskSpaceLookupURL(for url: URL) -> URL {
    let normalized = url.standardizedFileURL
    if FileManager.default.fileExists(atPath: normalized.path) {
      return normalized
    }
    return normalized.deletingLastPathComponent()
  }

  private func availableDiskSpaceBytes(at url: URL) -> Int64? {
    let targetURL = diskSpaceLookupURL(for: url)
    do {
      let values = try targetURL.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      if let free = values.volumeAvailableCapacityForImportantUsage {
        return Int64(free)
      }
      if let free = values.volumeAvailableCapacity {
        return Int64(free)
      }
    } catch {
      NativeLogger.w(
        "Facade", "Failed to read URL resource disk space",
        context: ["path": targetURL.path, "error": error.localizedDescription])
    }

    do {
      let attrs = try FileManager.default.attributesOfFileSystem(forPath: targetURL.path)
      if let free = attrs[.systemFreeSize] as? NSNumber {
        return free.int64Value
      }
      if let free = attrs[.systemFreeSize] as? Int64 {
        return free
      }
      if let free = attrs[.systemFreeSize] as? UInt64 {
        return free > UInt64(Int64.max) ? Int64.max : Int64(free)
      }
    } catch {
      NativeLogger.w(
        "Facade", "Failed to read filesystem disk space",
        context: ["path": targetURL.path, "error": error.localizedDescription])
    }
    return nil
  }

  private func setCaptureBackend(_ backend: CaptureBackend) {
    self.capture = backend
    resetOverlayUpdateDeduper()
    self.capture.onMicrophoneLevel = { [weak self] sample in
      self?.onMicrophoneLevel?(sample)
    }

    // Bridge backend callbacks into the facade state machine.
    self.capture.onStarted = { [weak self] url in
      guard let self else { return }
      let visibleRawURL = self.activeRecordingFileSession?.finalRawURL ?? url

      self.resetOverlayUpdateDeduper()
      self.state = .recording
      self.recordingStartedAt = Date()
      self.stateAsStr()
      self.refreshMicrophoneLevelMonitoring(resetMeter: true)
      self.currentRawURL = visibleRawURL

      // Write metadata sidecar when recording starts
      self.writeMetadataSidecar(for: url)

      self.onRecordingStateChanged?(true)
      if let sessionId = self.activeRecordingWorkflowSessionId {
        self.onRecordingStarted?(sessionId)
      }

      self.indicator.setState(
        .recording,
        pinned: self.prefs.indicatorPinned,
        onStopTapped: { [weak self] in self?.onIndicatorStopTapped?() },
        elapsedProvider: { [weak self] in self?.formattedElapsed() ?? "00:00:00" }
      )

      // Only update recording-time visual state; don't rebuild the window here.
      if self.camera.isShowing && self.effectiveOverlayEnabledForRecording {
        self.camera.setRecordingHighlight(enabled: self.prefs.overlayHighlight)
      }

      self.updateOverlayVisibility()

      self.updateCursorVisibility()

      self.startResult?(visibleRawURL.path)
      self.startResult = nil

      // If stop was requested while starting, stop now
      if self.pendingStop {
        self.state = .stopping
        self.stateAsStr()
        self.capture.stop()
      } else {
        self.onRecordingStateChanged?(true)
      }
    }

    self.capture.onFinished = { [weak self] url, error in
      guard let self else { return }

      NativeLogger.i(
        "Facade", "Backend onFinished called",
        context: [
          "url": url?.path ?? "nil",
          "hasError": error != nil,
          "error": error?.localizedDescription ?? "nil",
        ])

      let pendingStartResult = self.startResult
      let wasStarting = self.state == .starting
      if wasStarting {
        self.startResult = nil
      }

      var finalURL: URL? = url
      if let rawURL = url {
        // Update metadata sidecar before promoting files.
        self.updateMetadataSidecarOnFinish(for: rawURL)
        do {
          finalURL = try self.finalizeRecordingArtifactsIfNeeded(recordedRawURL: rawURL)
        } catch {
          NativeLogger.e(
            "Facade", "Failed to promote recording artifacts",
            context: [
              "tempRaw": rawURL.path,
              "finalRaw": self.activeRecordingFileSession?.finalRawURL.path ?? "nil",
              "error": error.localizedDescription,
            ])
          // Keep fallback path so the user still gets access to the captured file.
          finalURL = rawURL
        }
      }

      let completion = self.stopResult
      self.stopResult = nil

      self.pendingStop = false
      self.resetOverlayUpdateDeduper()
      self.state = .idle
      self.stateAsStr()
      self.refreshMicrophoneLevelMonitoring(resetMeter: false)
      self.recordingStartedAt = nil
      self.currentRawURL = nil
      self.activeRecordingFileSession = nil
      self.pendingMetadata = nil
      self.currentCaptureDisplayID = nil
      self.resetRecordingSessionSuppressions()

      self.indicator.setState(.hidden, pinned: self.prefs.indicatorPinned)

      self.updateOverlayVisibility()
      self.updateCursorVisibility()

      self.onRecordingStateChanged?(false)

      if let error {
        if let sessionId = self.activeRecordingWorkflowSessionId {
          self.onRecordingFailed?([
            "type": "recordingFailed",
            "sessionId": sessionId,
            "stage": wasStarting ? "start" : "finalize",
            "code": NativeErrorCode.recordingError,
            "error": error.localizedDescription,
          ])
        }
        if wasStarting {
          let startErr =
            (error as? FlutterError)
            ?? flutterError(NativeErrorCode.recordingError, error.localizedDescription)
          pendingStartResult?(startErr)
        }
        NativeLogger.e(
          "Facade", "Recording finished with error",
          context: [
            "error": error.localizedDescription
          ])
        completion?(flutterError(NativeErrorCode.recordingError, error.localizedDescription))
        self.indicator.setState(.hidden, pinned: self.prefs.indicatorPinned)
        self.activeRecordingWorkflowSessionId = nil
        return
      }

      if let path = finalURL?.path, let sessionId = self.activeRecordingWorkflowSessionId {
        NativeLogger.i("Facade", "Triggering onRecordingFinalized callback", context: ["path": path])
        self.onRecordingFinalized?(sessionId, path)
      }

      NativeLogger.i(
        "Facade", "Recording finished successfully",
        context: [
          "path": finalURL?.path ?? "nil"
        ])
      completion?(finalURL?.path)
      self.activeRecordingWorkflowSessionId = nil
    }
  }

  /// Writes the metadata sidecar file when recording starts.
  private func writeMetadataSidecar(for rawURL: URL) {
    guard let metadata = pendingMetadata else {
      NativeLogger.w("Facade", "No pending metadata to write")
      return
    }

    let metaURL = AppPaths.metadataSidecarURL(for: rawURL)
    do {
      try metadata.write(to: metaURL)
      NativeLogger.d(
        "Facade", "Wrote metadata sidecar", context: ["path": metaURL.lastPathComponent])
    } catch {
      NativeLogger.e(
        "Facade", "Failed to write metadata sidecar", context: ["error": error.localizedDescription]
      )
    }
  }

  /// Updates the metadata sidecar with end timestamp when recording finishes.
  private func updateMetadataSidecarOnFinish(for rawURL: URL) {
    let metaURL = AppPaths.metadataSidecarURL(for: rawURL)

    // Read existing metadata and update with end timestamp
    do {
      var metadata = try RecordingMetadata.read(from: metaURL)
      metadata = metadata.withEndTimestamp()
      try metadata.write(to: metaURL)
      NativeLogger.d(
        "Facade", "Updated metadata with end timestamp",
        context: ["path": metaURL.lastPathComponent])
    } catch {
      // If we can't update, log but don't fail - the recording is still valid
      NativeLogger.w(
        "Facade", "Could not update metadata end timestamp",
        context: ["error": error.localizedDescription])
    }
  }

  private func isStartingOrRecording() -> Bool {
    return state == .starting || state == .recording
  }
  private func exportFormatInfo(_ formatRaw: String) -> ExportFormatInfo {
    switch formatRaw.lowercased() {

    case "mp4":
      return .init(ext: "mp4", avFileType: .mp4)

    case "m4v":
      return .init(ext: "m4v", avFileType: .m4v)

    case "mov":
      return .init(ext: "mov", avFileType: .mov)

    case "gif":
      return .init(ext: "gif", avFileType: nil)  // handled by GIF pipeline, not AVAssetExportSession

    default:
      // Fallback safe default
      return .init(ext: "mov", avFileType: .mov)
    }
  }

  private func overlayCtx(_ extra: [String: Any] = [:]) -> [String: Any] {
    var ctx: [String: Any] = [
      "state": "\(state)",
      "overlayEnabled": prefs.overlayEnabled,
      "overlayLinked": prefs.overlayLinked,
      "cameraIsShowing": camera.isShowing,
      "overlayWindowID": camera.overlayWindowID.map { String($0) } ?? "nil",
      "selectedDisplayID": selectedDisplayID.map { String($0) } ?? "nil",
      "currentCaptureDisplayID": currentCaptureDisplayID.map { String($0) } ?? "nil",
      "cameraTargetDisplayID": camera.targetDisplayID.map { String($0) } ?? "nil",
      "videoDeviceId": prefs.videoDeviceId ?? "nil",
      "camAuth": "\(AVCaptureDevice.authorizationStatus(for: .video))",
      "overlaySize": prefs.overlaySize,
      "overlayPosition": prefs.overlayPosition,
    ]
    for (k, v) in extra { ctx[k] = v }
    return ctx
  }

  private func logOverlay(_ msg: String, _ extra: [String: Any] = [:]) {
    NativeLogger.d("OverlayDbg", msg, context: overlayCtx(extra))
  }
  private func stateAsStr(
    file: String = #file,
    line: Int = #line
  ) {
    var stateAsString = ""
    switch state {
    case .idle:
      stateAsString = "idle"
    case .starting:
      stateAsString = "starting"
    case .recording:
      stateAsString = "recording"
    case .stopping:
      stateAsString = "stopping"
    default:
      stateAsString = "error"
    }
    NativeLogger.d(
      "Facade", "Recroding state stateAsString: \(stateAsString)",
      context: ["file": file, "line": line])
  }

  private func mapAVStatus(_ s: AVAuthorizationStatus) -> PermissionState {
    switch s {
    case .authorized: return .granted
    case .denied: return .denied
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    @unknown default: return .denied
    }
  }

}
