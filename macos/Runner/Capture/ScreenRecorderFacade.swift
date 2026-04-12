import AVFoundation
import AppKit
import ApplicationServices
import AudioToolbox
import FlutterMacOS

private extension NSColor {
  var argbIntValue: Int {
    let resolved = usingColorSpace(.deviceRGB) ?? self
    let a = Int(round(resolved.alphaComponent * 255.0))
    let r = Int(round(resolved.redComponent * 255.0))
    let g = Int(round(resolved.greenComponent * 255.0))
    let b = Int(round(resolved.blueComponent * 255.0))
    return (a << 24) | (r << 16) | (g << 8) | b
  }
}

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

enum CachedRecordingsCleanupPolicy {
  static func canClear(recorderState: RecorderState) -> Bool {
    recorderState == .idle
  }
}

struct RecordedDurationTracker {
  private(set) var wallClockSessionStart: Date?
  private var activeSegmentStart: Date?
  private(set) var accumulatedRecordedDuration: TimeInterval = 0
  private(set) var isPaused = false

  mutating func start(at date: Date = Date()) {
    wallClockSessionStart = date
    activeSegmentStart = date
    accumulatedRecordedDuration = 0
    isPaused = false
  }

  mutating func pause(at date: Date = Date()) {
    guard let activeSegmentStart else { return }
    accumulatedRecordedDuration += max(0, date.timeIntervalSince(activeSegmentStart))
    self.activeSegmentStart = nil
    isPaused = true
  }

  mutating func resume(at date: Date = Date()) {
    guard wallClockSessionStart != nil, activeSegmentStart == nil else { return }
    activeSegmentStart = date
    isPaused = false
  }

  mutating func stop(at date: Date = Date()) {
    if let activeSegmentStart {
      accumulatedRecordedDuration += max(0, date.timeIntervalSince(activeSegmentStart))
    }
    activeSegmentStart = nil
    isPaused = false
  }

  mutating func reset() {
    wallClockSessionStart = nil
    activeSegmentStart = nil
    accumulatedRecordedDuration = 0
    isPaused = false
  }

  func currentRecordedDuration(at date: Date = Date()) -> TimeInterval {
    guard let activeSegmentStart else { return accumulatedRecordedDuration }
    return accumulatedRecordedDuration + max(0, date.timeIntervalSince(activeSegmentStart))
  }
}

struct RecordingPauseResumeCapabilities {
  enum Backend: String {
    case avFoundation = "avfoundation"
    case screenCaptureKit = "screencapturekit"
    case unsupported = "unsupported"
  }

  enum Strategy: String {
    case avFileOutput = "av_file_output"
    case recordingOutputSegmentation = "recording_output_segmentation"
    case unsupported = "unsupported"
  }

  let canPauseResume: Bool
  let backend: Backend
  let strategy: Strategy

  func asMap() -> [String: Any] {
    [
      "canPauseResume": canPauseResume,
      "backend": backend.rawValue,
      "strategy": strategy.rawValue,
    ]
  }

  static func current() -> RecordingPauseResumeCapabilities {
    if #available(macOS 15.0, *) {
      return RecordingPauseResumeCapabilities(
        canPauseResume: true,
        backend: .screenCaptureKit,
        strategy: .recordingOutputSegmentation
      )
    }

    return RecordingPauseResumeCapabilities(
      canPauseResume: true,
      backend: .avFoundation,
      strategy: .avFileOutput
    )
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

enum CaptureDestinationPreflightDecision {
  case proceed
  case noAvailableSpace
  case belowCriticalThreshold
}

enum CaptureDestinationPreflightPolicy {
  static func isNonProductionBuild(
    bundleIdentifier: String?,
    isDebugBuild: Bool = BuildEnvironment.isDebugBuild
  ) -> Bool {
    if isDebugBuild {
      return true
    }
    return bundleIdentifier?.lowercased().hasSuffix(".dev") == true
  }

  static func shouldBypassLowStorageCheck(
    requested: Bool,
    bundleIdentifier: String?,
    isDebugBuild: Bool = BuildEnvironment.isDebugBuild
  ) -> Bool {
    guard requested else { return false }
    return isNonProductionBuild(
      bundleIdentifier: bundleIdentifier,
      isDebugBuild: isDebugBuild
    )
  }

  static func decision(
    availableBytes: Int64?,
    requestedBypass: Bool,
    bundleIdentifier: String?,
    isDebugBuild: Bool = BuildEnvironment.isDebugBuild
  ) -> CaptureDestinationPreflightDecision {
    if shouldBypassLowStorageCheck(
      requested: requestedBypass,
      bundleIdentifier: bundleIdentifier,
      isDebugBuild: isDebugBuild
    ) {
      return .proceed
    }

    guard let availableBytes else {
      return .proceed
    }

    if availableBytes <= 0 {
      return .noAvailableSpace
    }

    if availableBytes < StorageInfoProvider.criticalThresholdBytes {
      return .belowCriticalThreshold
    }

    return .proceed
  }
}

enum BuildEnvironment {
  static var isDebugBuild: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
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

protocol MicrophoneLevelMonitoring: AnyObject {
  func start(deviceID: String?, onLevel: @escaping (MicrophoneLevelSample) -> Void)
  func stop(emitZero: Bool)
}

extension MicrophoneLevelMonitor: MicrophoneLevelMonitoring {}

private struct ExportFormatInfo {
  let ext: String
  let avFileType: AVFileType?  // nil for formats not handled by AVAssetExportSession (gif)
}

struct CaptureDestinationDiagnostics {
  static func url(for activeProjectRoot: URL?) -> URL {
    activeProjectRoot.map { RecordingProjectPaths.screenVideoURL(for: $0) } ?? AppPaths.tempRoot()
  }
}

enum OverlayRefreshAction: Equatable {
  case show
  case resize
  case reuseVisibleWindow
}

struct OverlayRefreshPlan {
  let action: OverlayRefreshAction

  static func make(
    isShowing: Bool,
    currentTargetDisplayID: CGDirectDisplayID?,
    desiredTargetDisplayID: CGDirectDisplayID?,
    currentPreferredSize: Double,
    desiredSize: Double
  ) -> OverlayRefreshPlan {
    let normalizedDesiredSize = max(120.0, desiredSize)

    guard isShowing else {
      return OverlayRefreshPlan(action: .show)
    }

    guard currentTargetDisplayID == desiredTargetDisplayID else {
      return OverlayRefreshPlan(action: .show)
    }

    if abs(currentPreferredSize - normalizedDesiredSize) > 0.001 {
      return OverlayRefreshPlan(action: .resize)
    }

    return OverlayRefreshPlan(action: .reuseVisibleWindow)
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
  private final class MainThreadOperationRelay: NSObject {
    private let operation: () -> Void

    init(operation: @escaping () -> Void) {
      self.operation = operation
    }

    @objc
    func invoke() {
      operation()
    }
  }

  private struct IndicatorConfiguration {
    let state: IndicatorState
    let onPauseTapped: (() -> Void)?
    let onStopTapped: (() -> Void)?
    let onResumeTapped: (() -> Void)?
    let elapsedProvider: (() -> String)?
  }

  // services
  private let prefs = PreferencesStore()
  private let saveFolder = SaveFolderStore()
  private let displaySvc = DisplayService()
  private let exporter = LetterboxExporter()
  private var captureFPS: Int = 30
  private let defaultZoomFollowStrength: CGFloat = 0.15
  private let cameraCaptureCoordinator = CameraCaptureCoordinator()
  private lazy var cameraRecorder = CameraRecorder(coordinator: cameraCaptureCoordinator)
  private lazy var camera = CameraOverlay(captureCoordinator: cameraCaptureCoordinator)
  private let cursor = CursorHighlighter()
  private let indicator = RecordingIndicator()
  private let recordingStore = RecordingStore()
  private let micLevelMonitor: MicrophoneLevelMonitoring

  private var capture: CaptureBackend = CaptureBackendAVFoundation()

  // Metadata for current recording session (written on start, updated on finish)
  private var pendingMetadata: RecordingMetadata?
  private var pendingCameraRecordingSession: CameraRecordingSession?
  private var pendingSeparateCameraFailure: FlutterError?
  private var activeRecordingProjectRoot: URL?

  // state
  private var state: RecorderState = .idle
  private var startResult: FlutterResult?
  private var pauseResult: FlutterResult?
  private var resumeResult: FlutterResult?
  private var stopResult: FlutterResult?
  private var pendingStop: Bool = false
  private var cancelRequestedDuringStart = false
  private var isPauseResumeMutationInFlight = false
  private var recordedDurationTracker = RecordedDurationTracker()
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
  private var suppressOverlayWindowDuringSeparateCameraCapture = false
  private var activeRecordingWorkflowSessionId: String?
  private var hasReceivedRecordingMicrophoneLevel = false

  // events out
  var onDevicesChanged: (() -> Void)?
  var onVideoDevicesChanged: (() -> Void)?
  var onIndicatorPauseTapped: (() -> Void)?
  var onIndicatorStopTapped: (() -> Void)?
  var onIndicatorResumeTapped: (() -> Void)?
  var onRecordingStateChanged: ((Bool) -> Void)?
  var onRecordingStarted: ((String) -> Void)?
  var onRecordingPaused: ((String) -> Void)?
  var onRecordingResumed: ((String) -> Void)?
  var onRecordingFinalized: ((String, String) -> Void)?
  var onRecordingFailed: (([String: Any]) -> Void)?
  var onAreaSelectionCleared: (() -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?
  var onCameraOverlayMoved: (([String: Any]) -> Void)?

  var isRecording: Bool { state == .recording || state == .paused }

  override init() {
    self.micLevelMonitor = MicrophoneLevelMonitor()
    super.init()
    commonInit()
  }

  #if DEBUG
    init(micLevelMonitor: MicrophoneLevelMonitoring) {
      self.micLevelMonitor = micLevelMonitor
      super.init()
      commonInit()
    }
  #endif

  private func commonInit() {
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
    cameraRecorder.onFailure = { [weak self] error in
      self?.handleSeparateCameraRecorderFailure(error)
    }

    setCaptureBackend(CaptureBackendAVFoundation())
    refreshMicrophoneLevelMonitoring(resetMeter: true)

    let didResetLegacyWorkspace = RecordingProjectPaths.performOneTimeLegacyWorkspaceResetIfNeeded(
      isNonProductionBuild: CaptureDestinationPreflightPolicy.isNonProductionBuild(
        bundleIdentifier: Bundle.main.bundleIdentifier
      )
    )
    if didResetLegacyWorkspace {
      NativeLogger.i(
        "Facade",
        "Reset legacy flat recordings workspace for project-folder schema"
      )
    }

    recordingStore.markInvalidReadyProjectsAsFailed()
    recordingStore.markInterruptedProjectsAsFailed()

    // Scan internal workspace on startup for diagnostics
    scanInternalWorkspaceOnStartup()
  }

  private enum MicrophoneTelemetrySource {
    case idleMonitor
    case recordingBackend
  }

  private func forwardMicrophoneLevel(
    _ sample: MicrophoneLevelSample,
    source: MicrophoneTelemetrySource
  ) {
    switch source {
    case .idleMonitor:
      if state != .idle && hasReceivedRecordingMicrophoneLevel {
        return
      }
    case .recordingBackend:
      if state != .idle && !hasReceivedRecordingMicrophoneLevel {
        hasReceivedRecordingMicrophoneLevel = true
        micLevelMonitor.stop(emitZero: false)
      }
    }

    onMicrophoneLevel?(sample)
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

  func getStorageSnapshot(result: @escaping FlutterResult) {
    let snapshot = StorageInfoProvider.buildSnapshot(
      captureDestinationURL: currentCaptureDestinationURL(),
      recordingsURL: AppPaths.recordingsRoot(),
      tempURL: AppPaths.tempRoot(),
      logsURL: AppPaths.logsRoot()
    )
    result(snapshot.asMap())
  }

  func getRecordingCapabilities(result: @escaping FlutterResult) {
    result(RecordingPauseResumeCapabilities.current().asMap())
  }

  func startRecording(args: [String: Any]?, result: @escaping FlutterResult) {
    guard state == .idle else {
      if let path = activeRecordingProjectRoot?.path {
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
    let allowLowStorageBypass = args?["allowLowStorageBypass"] as? Bool ?? false

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

      activeRecordingProjectRoot = nil
      pendingCameraRecordingSession = nil
      cancelRequestedDuringStart = false
      let projectId = RecordingProjectPaths.makeProjectID()
      let projectRoot = try RecordingProjectPaths.createProjectSkeleton(projectId: projectId)
      let screenVideoURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)

      try preflightCaptureDestination(
        screenVideoURL,
        allowLowStorageBypass: allowLowStorageBypass
      )
      activeRecordingProjectRoot = projectRoot

      NativeLogger.d(
        "Facade", "Prepared recording project",
        context: [
          "projectRoot": projectRoot.lastPathComponent,
          "screenVideo": screenVideoURL.lastPathComponent,
          "cameraMode": effectiveCameraCaptureModeForRecording.rawValue,
        ])

      if shouldRecordSeparateCameraAsset {
        pendingCameraRecordingSession = cameraRecordingSession(for: projectRoot)
      }

      pendingMetadata = RecordingMetadata.create(
        screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
        displayMode: prefs.displayMode,
        displayID: captureTarget.displayID,
        cropRect: captureTarget.cropRect,
        frameRate: frameRate,
        quality: prefs.recordingQuality,
        cursorEnabled: effectiveCursorEnabledForRecording,
        cursorLinked: prefs.cursorLinked,
        windowID: (prefs.displayMode == .singleAppWindow ? selectedAppWindowID : nil),
        excludedRecorderApp: prefs.excludeRecorderApp,
        camera: pendingCameraCaptureInfo(for: projectRoot),
        editorSeed: editorSeed(for: target)
      )

      let manifest = RecordingProjectManifest.create(
        projectId: projectId,
        displayName: RecordingProjectPaths.displayName(),
        includeCamera: shouldRecordSeparateCameraAsset
      )
      try manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRoot))

      let outputURL: () throws -> URL = {
        screenVideoURL
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
      let backend = CaptureBackendFactory.make(for: target)
      self.setCaptureBackend(backend)
      let startScreenCapture: (CGWindowID?) -> Void = { overlayID in
        let beginCapture = {
          self.suppressOverlayWindowDuringSeparateCameraCapture = self.shouldSuppressOverlayWindowDuringCapture
          self.updateOverlayVisibility()
          self.startCapture(
            target: target,
            frameRate: frameRate,
            outputURL: outputURL,
            overlayID: overlayID,
            systemAudioEnabled: systemAudioEnabled
          )
        }

        guard self.shouldRecordSeparateCameraAsset, let cameraSession = self.pendingCameraRecordingSession else {
          beginCapture()
          return
        }

        self.cameraRecorder.begin(session: cameraSession) { [weak self] result in
          self?.handleCameraRecorderBeginResult(
            result,
            beginCapture: beginCapture
          )
        }
      }

      if needsOverlay {
        self.ensureCameraPermission {
          self.logOverlay("camera permission OK (startRecording)")
          self.prepareCameraOverlayForRecordingStart(targetDisplayID: target.displayID) {
            overlayID in
            startScreenCapture(overlayID)
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
          startScreenCapture(overlayID)
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
    guard Thread.isMainThread else {
      runOverlayUITransitionOnMain(
        reason: "prepareCameraOverlayForRecordingStart",
        file: #file,
        line: #line
      ) { [weak self] in
        self?.prepareCameraOverlayForRecordingStart(
          targetDisplayID: targetDisplayID,
          completion: completion
        )
      }
      return
    }

    prepareCameraOverlayForRecordingStartOnMain(
      targetDisplayID: targetDisplayID,
      completion: completion
    )
  }

  private func prepareCameraOverlayForRecordingStartOnMain(
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
    hasReceivedRecordingMicrophoneLevel = false
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

    let cfg = makeCaptureStartConfig(
      target: target,
      frameRate: frameRate,
      outputURL: outputURL,
      effectiveOverlayID: effectiveOverlayID,
      systemAudioEnabled: systemAudioEnabled
    )
    self.capture.start(config: cfg)
  }

  private func makeCaptureStartConfig(
    target: CaptureTarget,
    frameRate: Int,
    outputURL: @escaping () throws -> URL,
    effectiveOverlayID: CGWindowID?,
    systemAudioEnabled: Bool
  ) -> CaptureStartConfig {
    CaptureStartConfig(
      target: target,
      quality: .native,
      frameRate: frameRate,
      includeAudioDevice: resolveAudioDevice(disableMicrophone: sessionDisableMicrophone),
      includeSystemAudio: systemAudioEnabled,
      makeOutputURL: outputURL,
      excludeRecorderApp: prefs.excludeRecorderApp,
      cameraOverlayWindowID: effectiveOverlayID,
      excludeCameraOverlayWindow: shouldRecordSeparateCameraAsset,
      excludeMicFromSystemAudio: prefs.excludeMicFromSystemAudio
    )
  }

  func stopRecording(result: @escaping FlutterResult) {
    switch state {
    case .idle:
      result(flutterError(NativeErrorCode.notRecording, ""))
    case .starting:
      pendingStop = true
      cancelRequestedDuringStart = true
      stopResult = result
    case .recording, .paused:
      stopResult = result
      if isPauseResumeMutationInFlight {
        pendingStop = true
        NativeLogger.i(
          "Facade", "Queued stop until pause/resume mutation completes",
          context: ["state": String(describing: state)])
        return
      }
      beginStoppingCapture()
    case .stopping:
      result(nil)
    }
  }

  func pauseRecording(result: @escaping FlutterResult) {
    let capabilities = RecordingPauseResumeCapabilities.current()
    guard capabilities.canPauseResume && capture.canPauseResume else {
      result(flutterError(NativeErrorCode.pauseResumeUnsupported, ""))
      return
    }

    switch state {
    case .paused:
      result(nil)
    case .recording:
      guard !isPauseResumeMutationInFlight else {
        result(nil)
        return
      }
      isPauseResumeMutationInFlight = true
      pauseResult = result
      NativeLogger.i("Facade", "Pause requested")
      capture.pause()
    case .starting, .stopping, .idle:
      result(
        flutterError(
          NativeErrorCode.invalidRecordingState,
          "Pause is only valid while recording."
        ))
    }
  }

  func resumeRecording(result: @escaping FlutterResult) {
    let capabilities = RecordingPauseResumeCapabilities.current()
    guard capabilities.canPauseResume && capture.canPauseResume else {
      result(flutterError(NativeErrorCode.pauseResumeUnsupported, ""))
      return
    }

    switch state {
    case .recording:
      result(nil)
    case .paused:
      guard !isPauseResumeMutationInFlight else {
        result(nil)
        return
      }
      isPauseResumeMutationInFlight = true
      resumeResult = result
      NativeLogger.i("Facade", "Resume requested")
      capture.resume()
    case .starting, .stopping, .idle:
      result(
        flutterError(
          NativeErrorCode.invalidRecordingState,
          "Resume is only valid while paused."
        ))
    }
  }

  func togglePauseRecording(result: @escaping FlutterResult) {
    switch state {
    case .recording:
      pauseRecording(result: result)
    case .paused:
      resumeRecording(result: result)
    case .idle, .starting, .stopping:
      result(
        flutterError(
          NativeErrorCode.invalidRecordingState,
          "Pause/resume is only valid for an active recording."
        ))
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
    applyIndicatorState()
    result(nil)
  }

  // MARK: helpers
  private func resolveTargetSize(
    sourceSize: CGSize,
    layout: String,
    resolution: String
  ) -> CGSize {
    // 1. Resolve Aspect Ratio from Layout Preset
    let safeSourceHeight = max(sourceSize.height, 1)
    let sourceAspect = sourceSize.width / safeSourceHeight
    let aspect: CGFloat
    switch layout {
    case "classic43": aspect = 4.0 / 3.0
    case "square11": aspect = 1.0
    case "youtube169": aspect = 16.0 / 9.0
    case "reel916": aspect = 9.0 / 16.0
    default: aspect = sourceAspect
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
      // Preserve the full source pixels on one axis and expand the other.
      guard layout != "auto", sourceSize.width > 0, sourceSize.height > 0 else {
        return sourceSize
      }
      if aspect >= sourceAspect {
        return CGSize(width: sourceSize.height * aspect, height: sourceSize.height)
      }
      return CGSize(width: sourceSize.width, height: sourceSize.width / aspect)
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

  private func loadRecordingProject(projectPath: String) -> RecordingProjectRef? {
    do {
      return try RecordingProjectRef.open(projectPath: projectPath)
    } catch {
      NativeLogger.w(
        "Scene",
        "Failed to open recording project",
        context: ["projectPath": projectPath, "error": error.localizedDescription]
      )
      return nil
    }
  }

  private func loadRecordingMetadata(projectRef: RecordingProjectRef) -> RecordingMetadata? {
    guard let metadataURL = projectRef.mediaSources().metadataURL else {
      return nil
    }

    do {
      return try RecordingMetadata.read(from: metadataURL)
    } catch {
      NativeLogger.w(
        "Scene",
        "Failed to load recording metadata",
        context: ["path": metadataURL.path, "error": error.localizedDescription]
      )
      return nil
    }
  }

  private func loadCameraRecordingMetadata(projectRef: RecordingProjectRef) -> CameraRecordingMetadata? {
    guard let metadataURL = projectRef.mediaSources().cameraMetadataURL else {
      return nil
    }

    do {
      let data = try Data(contentsOf: metadataURL)
      return try JSONDecoder().decode(CameraRecordingMetadata.self, from: data)
    } catch {
      NativeLogger.w(
        "Scene",
        "Failed to load camera recording metadata",
        context: ["path": metadataURL.path, "error": error.localizedDescription]
      )
      return nil
    }
  }

  private func resolvedCameraAssetURL(
    projectRef: RecordingProjectRef,
    explicitCameraPath: String?
  ) -> URL? {
    if let explicitCameraPath, !explicitCameraPath.isEmpty {
      let explicitURL = URL(fileURLWithPath: explicitCameraPath)
      guard FileManager.default.fileExists(atPath: explicitURL.path) else {
        NativeLogger.w(
          "Scene",
          "Explicit camera asset is missing; falling back to metadata resolution",
          context: ["path": explicitURL.path]
        )
        return nil
      }
      return explicitURL
    }

    return projectRef.mediaSources().cameraVideoURL
  }

  private func cameraCompositionParams(from editorSeed: RecordingMetadata.EditorSeed) -> CameraCompositionParams {
    CameraCompositionParams(
      visible: editorSeed.cameraVisible,
      layoutPreset: editorSeed.cameraLayoutPreset,
      normalizedCanvasCenter: editorSeed.cameraNormalizedCenter.map {
        CGPoint(x: $0.x, y: $0.y)
      },
      sizeFactor: editorSeed.cameraSizeFactor,
      shape: editorSeed.cameraShape,
      cornerRadius: editorSeed.cameraCornerRadius,
      opacity: editorSeed.cameraOpacity,
      mirror: editorSeed.cameraMirror,
      contentMode: editorSeed.cameraContentMode,
      zoomBehavior: editorSeed.cameraZoomBehavior,
      zoomScaleMultiplier: editorSeed.cameraZoomScaleMultiplier,
      introPreset: editorSeed.cameraIntroPreset,
      outroPreset: editorSeed.cameraOutroPreset,
      zoomEmphasisPreset: editorSeed.cameraZoomEmphasisPreset,
      introDurationMs: editorSeed.cameraIntroDurationMs,
      outroDurationMs: editorSeed.cameraOutroDurationMs,
      zoomEmphasisStrength: editorSeed.cameraZoomEmphasisStrength,
      borderWidth: editorSeed.cameraBorderWidth,
      borderColorArgb: editorSeed.cameraBorderColorArgb,
      shadowPreset: editorSeed.cameraShadow,
      chromaKeyEnabled: editorSeed.cameraChromaKeyEnabled,
      chromaKeyStrength: editorSeed.cameraChromaKeyStrength,
      chromaKeyColorArgb: editorSeed.cameraChromaKeyColorArgb
    )
  }

  private func cameraCompositionParamsMap(_ params: CameraCompositionParams) -> [String: Any] {
    var map: [String: Any] = [
      "visible": params.visible,
      "layoutPreset": params.layoutPreset.rawValue,
      "sizeFactor": params.sizeFactor,
      "shape": params.shape.rawValue,
      "cornerRadius": params.cornerRadius,
      "opacity": params.opacity,
      "mirror": params.mirror,
      "contentMode": params.contentMode.rawValue,
      "zoomBehavior": params.zoomBehavior.rawValue,
      "zoomScaleMultiplier": params.zoomScaleMultiplier,
      "introPreset": params.introPreset.rawValue,
      "outroPreset": params.outroPreset.rawValue,
      "zoomEmphasisPreset": params.zoomEmphasisPreset.rawValue,
      "introDurationMs": params.introDurationMs,
      "outroDurationMs": params.outroDurationMs,
      "zoomEmphasisStrength": params.zoomEmphasisStrength,
      "borderWidth": params.borderWidth,
      "shadowPreset": params.shadowPreset,
      "chromaKeyEnabled": params.chromaKeyEnabled,
      "chromaKeyStrength": params.chromaKeyStrength,
    ]

    if let normalizedCanvasCenter = params.normalizedCanvasCenter {
      map["normalizedCanvasCenter"] = [
        "x": normalizedCanvasCenter.x,
        "y": normalizedCanvasCenter.y,
      ]
    }
    if let borderColorArgb = params.borderColorArgb {
      map["borderColorArgb"] = borderColorArgb
    }
    if let chromaKeyColorArgb = params.chromaKeyColorArgb {
      map["chromaKeyColorArgb"] = chromaKeyColorArgb
    }

    return map
  }

  private func anyCameraParamOverride(in args: [String: Any]) -> Bool {
    args.keys.contains { $0.hasPrefix("camera") }
  }

  private func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String {
      switch string.lowercased() {
      case "true", "1", "yes": return true
      case "false", "0", "no": return false
      default: return nil
      }
    }
    return nil
  }

  private func explicitCameraCompositionParams(
    from args: [String: Any],
    fallback: CameraCompositionParams?
  ) -> CameraCompositionParams? {
    guard anyCameraParamOverride(in: args) else { return fallback }

    var params = fallback ?? .hidden

    if let visible = boolValue(args["cameraVisible"]) {
      params.visible = visible
    }
    if let rawPreset = args["cameraLayoutPreset"] as? String,
      let preset = CameraLayoutPreset(rawValue: rawPreset)
    {
      params.layoutPreset = preset
    }
    if let rawShape = args["cameraShape"] as? String,
      let shape = CameraShape(rawValue: rawShape)
    {
      params.shape = shape
    }
    if let rawContentMode = args["cameraContentMode"] as? String,
      let contentMode = CameraContentMode(rawValue: rawContentMode)
    {
      params.contentMode = contentMode
    }
    if let rawZoomBehavior = args["cameraZoomBehavior"] as? String {
      params.zoomBehavior = CameraZoomBehavior.from(rawValue: rawZoomBehavior)
    }
    if let zoomScaleMultiplier = doubleValue(args["cameraZoomScaleMultiplier"]) {
      params.zoomScaleMultiplier = min(max(zoomScaleMultiplier, 0.0), 1.0)
    }
    if let rawIntroPreset = args["cameraIntroPreset"] as? String {
      params.introPreset = CameraIntroPreset.from(rawValue: rawIntroPreset)
    }
    if let rawOutroPreset = args["cameraOutroPreset"] as? String {
      params.outroPreset = CameraOutroPreset.from(rawValue: rawOutroPreset)
    }
    if let rawZoomEmphasisPreset = args["cameraZoomEmphasisPreset"] as? String {
      params.zoomEmphasisPreset = CameraZoomEmphasisPreset.from(rawValue: rawZoomEmphasisPreset)
    }
    if let introDurationMs = args["cameraIntroDurationMs"] as? Int {
      params.introDurationMs = min(max(introDurationMs, 80), 600)
    } else if let introDurationMs = doubleValue(args["cameraIntroDurationMs"]) {
      params.introDurationMs = min(max(Int(introDurationMs.rounded()), 80), 600)
    }
    if let outroDurationMs = args["cameraOutroDurationMs"] as? Int {
      params.outroDurationMs = min(max(outroDurationMs, 80), 600)
    } else if let outroDurationMs = doubleValue(args["cameraOutroDurationMs"]) {
      params.outroDurationMs = min(max(Int(outroDurationMs.rounded()), 80), 600)
    }
    if let zoomEmphasisStrength = doubleValue(args["cameraZoomEmphasisStrength"]) {
      params.zoomEmphasisStrength = min(max(zoomEmphasisStrength, 0.0), 0.2)
    }
    if let sizeFactor = doubleValue(args["cameraSizeFactor"]) {
      params.sizeFactor = sizeFactor
    }
    if let cornerRadius = doubleValue(args["cameraCornerRadius"]) {
      params.cornerRadius = cornerRadius
    }
    if let opacity = doubleValue(args["cameraOpacity"]) {
      params.opacity = opacity
    }
    if let mirror = boolValue(args["cameraMirror"]) {
      params.mirror = mirror
    }
    if let borderWidth = doubleValue(args["cameraBorderWidth"]) {
      params.borderWidth = borderWidth
    }
    if let borderColorArgb = args["cameraBorderColorArgb"] as? Int {
      params.borderColorArgb = borderColorArgb
    }
    if let shadowPreset = args["cameraShadowPreset"] as? Int {
      params.shadowPreset = shadowPreset
    }
    if let chromaKeyEnabled = boolValue(args["cameraChromaKeyEnabled"]) {
      params.chromaKeyEnabled = chromaKeyEnabled
    }
    if let chromaKeyStrength = doubleValue(args["cameraChromaKeyStrength"]) {
      params.chromaKeyStrength = chromaKeyStrength
    }
    if let chromaKeyColorArgb = args["cameraChromaKeyColorArgb"] as? Int {
      params.chromaKeyColorArgb = chromaKeyColorArgb
    }
    if let center = args["cameraNormalizedCenter"] as? [String: Any],
      let x = doubleValue(center["x"]),
      let y = doubleValue(center["y"])
    {
      params.normalizedCanvasCenter = CGPoint(x: x, y: y)
    } else if args.keys.contains("cameraNormalizedCenter") {
      params.normalizedCanvasCenter = nil
    }

    return params
  }

  func resolvePreviewMediaSources(
    projectPath: String,
    explicitCameraPath: String? = nil
  ) -> PreviewMediaSources? {
    guard let projectRef = loadRecordingProject(projectPath: projectPath) else {
      return nil
    }
    let mediaSources = projectRef.mediaSources()
    let resolvedCameraURL = resolvedCameraAssetURL(
      projectRef: projectRef,
      explicitCameraPath: explicitCameraPath
    )
    let recordingMetadata = loadRecordingMetadata(projectRef: projectRef)
    let cameraMetadata = loadCameraRecordingMetadata(projectRef: projectRef)
    let cameraSyncTimeline = CameraSyncTimelineResolver.resolve(
      recordingMetadata: recordingMetadata,
      cameraMetadata: cameraMetadata,
      screenAsset: AVAsset(url: URL(fileURLWithPath: mediaSources.screenPath)),
      cameraAsset: resolvedCameraURL.map(AVAsset.init(url:)),
      logContext: [
        "context": "preview",
        "projectPath": projectPath,
      ]
    )

    NativeLogger.d(
      "Scene",
      "Resolved preview media sources",
      context: [
        "projectPath": projectPath,
        "screenPath": mediaSources.screenPath,
        "cameraPath": resolvedCameraURL?.path ?? "nil",
        "metadataPath": mediaSources.metadataPath ?? "nil",
        "cursorPath": mediaSources.cursorPath ?? "nil",
        "zoomManualPath": mediaSources.zoomManualPath ?? "nil",
        "cameraSyncSegments": cameraSyncTimeline?.segments.count ?? 0,
      ]
    )

    return PreviewMediaSources(
      projectPath: projectPath,
      screenPath: mediaSources.screenPath,
      cameraPath: resolvedCameraURL?.path,
      metadataPath: mediaSources.metadataPath,
      cursorPath: mediaSources.cursorPath,
      zoomManualPath: mediaSources.zoomManualPath,
      cameraSyncTimeline: cameraSyncTimeline
    )
  }

  private func resolvePreviewSceneComponents(
    projectPath: String,
    explicitCameraPath: String? = nil,
    args: [String: Any]? = nil
  ) -> (mediaSources: PreviewMediaSources, cameraParams: CameraCompositionParams?)? {
    guard let mediaSources = resolvePreviewMediaSources(
      projectPath: projectPath,
      explicitCameraPath: explicitCameraPath
    ) else {
      return nil
    }
    let cameraParams = resolveCameraCompositionParams(
      projectPath: projectPath,
      args: args
    )
    return (mediaSources, cameraParams)
  }

  func resolvePreviewScene(
    projectPath: String,
    screenParams: CompositionParams,
    explicitCameraPath: String? = nil,
    args: [String: Any]? = nil
  ) -> PreviewScene? {
    guard let components = resolvePreviewSceneComponents(
      projectPath: projectPath,
      explicitCameraPath: explicitCameraPath,
      args: args
    ) else {
      return nil
    }

    return PreviewScene(
      mediaSources: components.mediaSources,
      screenParams: screenParams,
      cameraParams: components.cameraParams
    )
  }

  private struct CameraExportCapabilitySet {
    let shapeMask: Bool
    let cornerRadius: Bool
    let border: Bool
    let shadow: Bool
    let chromaKey: Bool

    var payload: [String: Bool] {
      [
        "shapeMask": shapeMask,
        "cornerRadius": cornerRadius,
        "border": border,
        "shadow": shadow,
        "chromaKey": chromaKey,
      ]
    }
  }

  private func cameraExportCapabilities(for mediaSources: PreviewMediaSources) -> CameraExportCapabilitySet {
    guard mediaSources.cameraPath?.isEmpty == false else {
      return CameraExportCapabilitySet(
        shapeMask: true,
        cornerRadius: true,
        border: true,
        shadow: true,
        chromaKey: true
      )
    }

    return CameraExportCapabilitySet(
      shapeMask: true,
      cornerRadius: true,
      border: true,
      shadow: true,
      chromaKey: true
    )
  }

  private func exportSanitizedCameraParams(
    _ params: CameraCompositionParams?,
    cameraPath: String?
  ) -> CameraCompositionParams? {
    guard let params else { return nil }
    guard let cameraPath, !cameraPath.isEmpty else { return params }
    return params
  }

  func resolveCameraCompositionParams(
    projectPath: String,
    args: [String: Any]? = nil
  ) -> CameraCompositionParams? {
    let metadata = loadRecordingProject(projectPath: projectPath).flatMap { projectRef in
      loadRecordingMetadata(projectRef: projectRef)
    }
    let seededParams = metadata.map { cameraCompositionParams(from: $0.editorSeed) }
    let resolved = explicitCameraCompositionParams(from: args ?? [:], fallback: seededParams)
    var context: [String: Any] = [
      "projectPath": projectPath,
      "hasSeed": seededParams != nil,
      "hasExplicitArgs": args.map(anyCameraParamOverride(in:)) ?? false,
      "cameraPreviewChangeKind":
        (args?["cameraPreviewChangeKind"] as? String) ?? CameraPreviewChangeKind.none.rawValue,
      "visible": resolved?.visible ?? false,
      "layoutPreset": resolved?.layoutPreset.rawValue ?? "nil",
    ]
    if let center = resolved?.normalizedCanvasCenter {
      context["normalizedCenterX"] = center.x
      context["normalizedCenterY"] = center.y
    }

    NativeLogger.d(
      "Scene",
      "Resolved camera composition params",
      context: context
    )

    return resolved
  }

  func getRecordingSceneInfo(projectPath: String, result: @escaping FlutterResult) {
    guard let components = resolvePreviewSceneComponents(projectPath: projectPath) else {
      result(
        FlutterError(
          code: "SCENE_INPUT_MISSING",
          message: "Recording project not found. It may have been moved or deleted.",
          details: projectPath
        )
      )
      return
    }
    let mediaSources = components.mediaSources
    let cameraParams = components.cameraParams
    let exportCapabilities = cameraExportCapabilities(for: mediaSources)

    var payload: [String: Any] = [
      "projectPath": mediaSources.projectPath,
      "screenPath": mediaSources.screenPath,
      "cameraExportCapabilities": exportCapabilities.payload,
    ]
    if let cameraPath = mediaSources.cameraPath {
      payload["cameraPath"] = cameraPath
    }
    if let metadataPath = mediaSources.metadataPath {
      payload["metadataPath"] = metadataPath
    }
    if let cameraParams {
      payload["camera"] = cameraCompositionParamsMap(cameraParams)
    }

    result(payload)
  }

  func processVideo(
    projectPath: String,
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
    cameraPreviewChangeKind: CameraPreviewChangeKind,
    sessionId: String?,
    cameraPath: String?,
    cameraParams: CameraCompositionParams?,
    result: @escaping FlutterResult
  ) {
    guard let mediaSources = resolvePreviewMediaSources(
      projectPath: projectPath,
      explicitCameraPath: cameraPath
    ) else {
      result(
        FlutterError(
          code: "PROCESS_INPUT_MISSING",
          message: "Recording project not found. It may have been moved or deleted.",
          details: projectPath
        )
      )
      return
    }
    let inputURL = URL(fileURLWithPath: mediaSources.screenPath)
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
        "projectPath": projectPath,
        "source": inputURL.path,
        "layout": layout,
        "resolution": resolution,
        "fit": fit,
        "targetSize": "\(targetSize.width)x\(targetSize.height)",
        "zoomSegments": zoomSegments.map { "\($0.count)" } ?? "nil",
        "cameraPreviewChangeKind": cameraPreviewChangeKind.rawValue,
        "cameraNormalizedCenterX": cameraParams?.normalizedCanvasCenter?.x ?? "nil",
        "cameraNormalizedCenterY": cameraParams?.normalizedCanvasCenter?.y ?? "nil",
      ])

    let previewScene = PreviewScene(
      mediaSources: mediaSources,
      screenParams: params,
      cameraParams: cameraParams,
      cameraPreviewChangeKind: cameraPreviewChangeKind
    )

    DispatchQueue.main.async {
      updateActiveInlinePreviewScene(
        sessionId: sessionId,
        scene: previewScene
      )
      let viewSessionId = inlinePreviewViewInstance?.currentSessionId
      let route = routePreviewSceneRequest(
        sessionId: sessionId,
        scene: previewScene
      )
      NativeLogger.d(
        "Preview", "Routed preview scene update",
        context: [
          "sessionId": sessionId ?? "nil",
          "viewSessionId": viewSessionId ?? "nil",
          "hasInlinePreviewView": inlinePreviewViewInstance != nil,
          "hasActivePreviewState": activeInlinePreviewState != nil,
          "route": route.rawValue,
        ])
    }
    result(projectPath)
  }

  func previewSetCameraPlacement(
    sessionId: String?,
    cameraPreviewChangeKind: CameraPreviewChangeKind,
    cameraParams: CameraCompositionParams?,
    result: @escaping FlutterResult
  ) {
    updateActiveInlinePreviewCameraPlacementOverride(
      sessionId: sessionId,
      cameraParams: cameraParams,
      changeKind: cameraPreviewChangeKind
    )
    if let view = inlinePreviewViewInstance {
      if let sessionId, view.currentSessionId != sessionId {
        result(nil)
        return
      }
      view.updateCameraPlacementPreview(
        cameraParams: cameraParams,
        changeKind: cameraPreviewChangeKind
      )
    } else if let sessionId,
      let request = pendingPreviewOpenRequest,
      request.sessionId != sessionId
    {
      result(nil)
      return
    }
    result(nil)
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
    updateActiveInlinePreviewAudioMixOverride(
      sessionId: sessionId,
      gainDb: clampedGainDb,
      volumePercent: clampedVolumePercent
    )
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
    projectPath: String,
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
    cameraPath: String?,
    cameraParams: CameraCompositionParams?,
    onProgress: ((Double) -> Void)? = nil,
    result: @escaping FlutterResult
  ) {
    guard let projectRef = loadRecordingProject(projectPath: projectPath) else {
      result(
        FlutterError(
          code: "EXPORT_INPUT_MISSING",
          message: "Recording project not found. It may have been moved or deleted.",
          details: projectPath
        )
      )
      return
    }
    let mediaSources = projectRef.mediaSources()
    let inputURL = mediaSources.screenVideoURL
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
    let exportCameraParams = exportSanitizedCameraParams(cameraParams, cameraPath: cameraPath)

    exporter.export(
      project: projectRef,
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
      cameraParams: exportCameraParams,
      onProgress: onProgress,
    ) { res in
      switch res {
      case .success(let final):
        if var manifest = try? RecordingProjectManifest.read(
          from: RecordingProjectPaths.manifestURL(for: projectRef.rootURL)
        ) {
          manifest.appendExportRecord(
            format: format,
            resolution: resolution,
            destinationPath: final.path
          )
          try? manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRef.rootURL))
        }
        // Cleanup raw recording and sidecars after successful export
        DispatchQueue.global(qos: .utility).async {
          recordingStoreRef.cleanupAfterExport(
            projectRootURL: projectRef.rootURL,
            keepOriginals: keepOriginals
          )
        }
        result(final.path)
      case .failure(let err):
        result(self.flutterExportFailure(from: err))
      }
    }
  }

  private func flutterExportFailure(from error: Error) -> FlutterError {
    let nsError = error as NSError
    if let nativeErrorCode = nsError.userInfo["nativeErrorCode"] as? String,
      nativeErrorCode == NativeErrorCode.advancedCameraExportFailed
    {
      var details: [String: Any] = [:]
      if let stage = nsError.userInfo["stage"] as? String {
        details["stage"] = stage
      }
      if let reason = nsError.userInfo["reason"] as? String {
        details["reason"] = reason
      }
      if let context = nsError.userInfo["context"] {
        details["context"] = context
      }
      return FlutterError(
        code: nativeErrorCode,
        message: nsError.localizedDescription,
        details: details.isEmpty ? nil : details
      )
    }

    return FlutterError(
      code: NativeErrorCode.exportError,
      message: error.localizedDescription,
      details: nil
    )
  }

  func cancelExport() {
    exporter.cancel()
  }

  func getZoomSegments(projectPath: String, result: @escaping FlutterResult) {
    guard let projectRef = loadRecordingProject(projectPath: projectPath) else {
      result([])
      return
    }
    let mediaSources = projectRef.mediaSources()
    let videoURL = mediaSources.screenVideoURL
    let asset = AVAsset(url: videoURL)

    // 1. Check if asset is valid and duration is finite
    guard asset.duration.isNumeric else {
      NativeLogger.e(
        "Facade", "getZoomSegments: duration is not numeric", context: ["projectPath": projectPath])
      result([])
      return
    }
    let durationSeconds = asset.duration.seconds

    // 2. Locate cursor sidecar
    guard let cursorURL = mediaSources.cursorDataURL else {
      NativeLogger.w(
        "Facade", "getZoomSegments: cursor.json missing", context: ["projectPath": projectPath])
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
    hasReceivedRecordingMicrophoneLevel = false
    refreshMicrophoneLevelMonitoring(resetMeter: false)
    recordedDurationTracker.reset()
    resetRecordingSessionSuppressions()
    if let projectRoot = activeRecordingProjectRoot {
      updateProjectManifestStatus(.failed, projectRoot: projectRoot)
    }
    activeRecordingProjectRoot = nil
    pendingCameraRecordingSession = nil
    cancelRequestedDuringStart = false
    pendingSeparateCameraFailure = nil
    pendingMetadata = nil
    if pendingStop {
      stopResult?(err)
      stopResult = nil
      pendingStop = false
    }
    resolvePauseResumeSuccessIfNeeded()
    applyIndicatorState()
    updateOverlayVisibility()
    updateCursorVisibility()
    activeRecordingWorkflowSessionId = nil
    startResult?(err)
    startResult = nil
  }
  private func formattedElapsed() -> String {
    let secs = max(0, Int(recordedDurationTracker.currentRecordedDuration()))
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

  private var effectiveCameraCaptureModeForRecording: CameraCaptureMode {
    prefs.cameraCaptureMode
  }

  private var shouldRecordSeparateCameraAsset: Bool {
    effectiveOverlayEnabledForRecording
      && prefs.overlayLinked
      && effectiveCameraCaptureModeForRecording == .separateCameraAsset
  }

  private var shouldSuppressOverlayWindowDuringCapture: Bool {
    shouldRecordSeparateCameraAsset
      && !capture.supportsLiveOverlayExclusionDuringSeparateCameraCapture
  }

  private var effectiveCursorEnabledForRecording: Bool {
    prefs.cursorEnabled && !sessionDisableCursorHighlight
  }

  private func resetRecordingSessionSuppressions() {
    sessionDisableMicrophone = false
    sessionDisableCameraOverlay = false
    sessionDisableCursorHighlight = false
    suppressOverlayWindowDuringSeparateCameraCapture = false
    pendingSeparateCameraFailure = nil
  }

  private func cameraRecordingDimensions(deviceID: String?) -> CameraRecordingMetadata.Dimensions? {
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

  private func cameraNominalFrameRate(deviceID: String?) -> Double? {
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

  private func cameraRecordingSession(for projectRoot: URL) -> CameraRecordingSession {
    CameraRecordingSession(
      outputURL: RecordingProjectPaths.cameraRawURL(for: projectRoot),
      metadataURL: RecordingProjectPaths.cameraMetadataURL(for: projectRoot),
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      segmentDirectoryURL: RecordingProjectPaths.cameraSegmentsDirectoryURL(for: projectRoot),
      deviceId: prefs.videoDeviceId,
      mirroredRaw: prefs.overlayMirror,
      nominalFrameRate: cameraNominalFrameRate(deviceID: prefs.videoDeviceId),
      dimensions: cameraRecordingDimensions(deviceID: prefs.videoDeviceId)
    )
  }

  private func pendingCameraCaptureInfo(for projectRoot: URL?) -> RecordingMetadata.CameraCaptureInfo? {
    guard shouldRecordSeparateCameraAsset, projectRoot != nil else { return nil }
    return RecordingMetadata.CameraCaptureInfo(
      mode: .separateCameraAsset,
      enabled: true,
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      deviceId: prefs.videoDeviceId,
      mirroredRaw: prefs.overlayMirror,
      nominalFrameRate: cameraNominalFrameRate(deviceID: prefs.videoDeviceId),
      dimensions: cameraRecordingDimensions(deviceID: prefs.videoDeviceId).map {
        RecordingMetadata.Dimensions(width: $0.width, height: $0.height)
      },
      segments: []
    )
  }

  private func findScreen(displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        == displayID
    }
  }

  private func initialEditorCameraCenter(for target: CaptureTarget) -> RecordingMetadata.NormalizedPoint? {
    guard let normalizedCenter = camera.currentCustomNormalizedCenter else {
      return nil
    }

    guard let screen = findScreen(displayID: target.displayID) else {
      return RecordingMetadata.NormalizedPoint(
        x: Double(normalizedCenter.x),
        y: Double(normalizedCenter.y)
      )
    }

    let visibleFrame = screen.visibleFrame
    let absoluteX = visibleFrame.minX + (CGFloat(normalizedCenter.x) * visibleFrame.width)
    let absoluteY = visibleFrame.minY + (CGFloat(normalizedCenter.y) * visibleFrame.height)

    let contentRect = target.cropRect ?? visibleFrame
    guard contentRect.width > 0, contentRect.height > 0 else {
      return nil
    }

    let converted = RecordingMetadata.NormalizedPoint(
      x: Double(min(max((absoluteX - contentRect.minX) / contentRect.width, 0.0), 1.0)),
      y: Double(min(max((absoluteY - contentRect.minY) / contentRect.height, 0.0), 1.0))
    )

    return converted
  }

  private func editorSeed(for target: CaptureTarget) -> RecordingMetadata.EditorSeed {
    let sourceSize =
      target.cropRect?.size
      ?? findScreen(displayID: target.displayID)?.visibleFrame.size
      ?? CGSize(width: 1920, height: 1080)
    let shortEdge = max(1.0, min(sourceSize.width, sourceSize.height))
    let sizeFactor = min(max(prefs.overlaySize / shortEdge, 0.08), 0.45)

    return RecordingMetadata.EditorSeed(
      cameraVisible: effectiveOverlayEnabledForRecording && prefs.overlayLinked,
      cameraLayoutPreset: CameraLayoutPreset.fromOverlayPosition(prefs.overlayPosition),
      cameraNormalizedCenter: initialEditorCameraCenter(for: target),
      cameraSizeFactor: sizeFactor,
      cameraShape: CameraShape.fromOverlayShape(prefs.overlayShape),
      cameraCornerRadius: prefs.overlayRoundness,
      cameraBorderWidth: Double(camera.borderWidth),
      cameraBorderColorArgb: camera.borderColor.argbIntValue,
      cameraShadow: prefs.overlayShadow,
      cameraOpacity: prefs.overlayOpacity,
      cameraMirror: prefs.overlayMirror,
      cameraContentMode: .fill,
      cameraZoomBehavior: CameraCompositionParams.defaultZoomBehavior,
      cameraZoomScaleMultiplier: CameraCompositionParams.defaultZoomScaleMultiplier,
      cameraIntroPreset: CameraCompositionParams.defaultIntroPreset,
      cameraOutroPreset: CameraCompositionParams.defaultOutroPreset,
      cameraZoomEmphasisPreset: .none,
      cameraIntroDurationMs: CameraCompositionParams.defaultIntroDurationMs,
      cameraOutroDurationMs: CameraCompositionParams.defaultOutroDurationMs,
      cameraZoomEmphasisStrength: CameraCompositionParams.defaultZoomEmphasisStrength,
      cameraChromaKeyEnabled: camera.chromaKeyEnabled,
      cameraChromaKeyStrength: camera.chromaKeyStrength,
      cameraChromaKeyColorArgb: camera.chromaKeyColor.argbIntValue
    )
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
    guard Thread.isMainThread else {
      runOverlayUITransitionOnMain(
        reason: "updateOverlayVisibility",
        file: file,
        line: line
      ) { [weak self] in
        self?.updateOverlayVisibility(file: file, line: line)
      }
      return
    }

    updateOverlayVisibilityOnMain(file: file, line: line)
  }

  private func updateOverlayVisibilityOnMain(
    file: String,
    line: Int
  ) {
    NativeLogger.d("Facade", "updateOverlayVisibility file= \(file):\(line)")
    let shouldShow =
      effectiveOverlayEnabledForRecording && (!prefs.overlayLinked || isShowingRecordingLinkedVisuals())
      && !suppressOverlayWindowDuringSeparateCameraCapture
    logOverlay(
      "updateOverlayVisibility ENTER",
      [
        "file": file, "line": line,
        "shouldShow": shouldShow,
        "isShowingRecordingLinkedVisuals": isShowingRecordingLinkedVisuals(),
        "suppressedForSeparateCameraCapture": suppressOverlayWindowDuringSeparateCameraCapture,
      ])
    stateAsStr()

    if shouldShow {
      let desiredTargetDisplayID = currentCaptureDisplayID ?? selectedDisplayID
      let overlayRefreshPlan = OverlayRefreshPlan.make(
        isShowing: camera.isShowing,
        currentTargetDisplayID: camera.targetDisplayID,
        desiredTargetDisplayID: desiredTargetDisplayID,
        currentPreferredSize: camera.preferredSize,
        desiredSize: prefs.overlaySize
      )

      camera.targetDisplayID = desiredTargetDisplayID
      camera.setDevice(id: prefs.videoDeviceId)
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
      camera.setRecordingHighlight(enabled: isActivelyRecording && prefs.overlayHighlight)

      logOverlay(
        "updateOverlayVisibility -> applying camera visibility",
        [
          "size": prefs.overlaySize,
          "targetDisplay": desiredTargetDisplayID.map { String($0) } ?? "nil",
          "action": "\(overlayRefreshPlan.action)",
        ])

      switch overlayRefreshPlan.action {
      case .reuseVisibleWindow:
        logOverlay("updateOverlayVisibility -> reusing visible camera window")
        syncOverlayWindowIntoCaptureIfNeeded()

      case .resize:
        logOverlay("updateOverlayVisibility -> resizing visible camera window")
        camera.resize(size: prefs.overlaySize)
        syncOverlayWindowIntoCaptureIfNeeded()

      case .show:
        camera.show(size: prefs.overlaySize) { [weak self] _ in
          guard let self else { return }
          self.logOverlay(
            "camera.show callback in updateOverlayVisibility",
            [
              "state": "\(self.state)",
              "overlayWindowID": self.camera.overlayWindowID.map { String($0) } ?? "nil",
            ])
          self.syncOverlayWindowIntoCaptureIfNeeded()
        }
      }
    } else {
      logOverlay("updateOverlayVisibility -> hiding camera")
      camera.hide()
      if state == .recording || state == .paused {
        logOverlay("updateOverlayVisibility -> capture.updateOverlay(nil)")
        sendOverlayUpdateIfNeeded(nil)
      }
    }
  }

  private func overlayWindowIDForCapture(liveOverlayWindowID: CGWindowID?) -> CGWindowID? {
    guard shouldRecordSeparateCameraAsset else {
      return liveOverlayWindowID
    }

    return capture.supportsLiveOverlayExclusionDuringSeparateCameraCapture
      ? liveOverlayWindowID
      : nil
  }

  private func syncOverlayWindowIntoCaptureIfNeeded() {
    guard state == .recording else { return }

    if shouldRecordSeparateCameraAsset {
      let overlayWindowID = overlayWindowIDForCapture(liveOverlayWindowID: camera.overlayWindowID)
      logOverlay(
        "separate camera mode -> syncing overlay window for capture",
        [
          "windowID": overlayWindowID.map { String($0) } ?? "nil",
          "backendSupportsLiveExclusion": "\(capture.supportsLiveOverlayExclusionDuringSeparateCameraCapture)",
        ])
      lastOverlayWindowID = overlayWindowID
      sendOverlayUpdateIfNeeded(overlayWindowID)
      return
    }

    logOverlay(
      "calling capture.updateOverlay(windowID:)",
      [
        "windowID": camera.overlayWindowID.map { String($0) } ?? "nil",
        "backend": "\(type(of: capture))",
      ])
    lastOverlayWindowID = camera.overlayWindowID
    sendOverlayUpdateIfNeeded(camera.overlayWindowID)
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

  private func runOnMainIfNeeded(
    reason: String,
    category: String,
    file: String? = nil,
    line: Int? = nil,
    operation: @escaping () -> Void
  ) {
    if Thread.isMainThread {
      operation()
      return
    }

    var context: [String: String] = [:]
    if let file {
      context["file"] = file
    }
    if let line {
      context["line"] = String(line)
    }

    NativeLogger.w(
      category,
      "\(reason) requested off main thread; dispatching to main",
      context: context
    )
    let relay = MainThreadOperationRelay(operation: operation)
    relay.performSelector(
      onMainThread: #selector(MainThreadOperationRelay.invoke),
      with: nil,
      waitUntilDone: false
    )
  }

  private func runOverlayUITransitionOnMain(
    reason: String,
    file: String = #file,
    line: Int = #line,
    operation: @escaping () -> Void
  ) {
    runOnMainIfNeeded(
      reason: reason,
      category: "OverlayDbg",
      file: file,
      line: line,
      operation: operation
    )
  }

  private func handleCameraRecorderBeginResult(
    _ result: Result<Void, Error>,
    beginCapture: @escaping () -> Void,
    onFailure: ((FlutterError) -> Void)? = nil
  ) {
    let failureHandler: (FlutterError) -> Void = onFailure ?? { [weak self] error in
      self?.finishStartWithError(error)
    }

    runOnMainIfNeeded(reason: "cameraRecorder.begin completion", category: "Facade") {
      switch result {
      case .success:
        beginCapture()
      case .failure(let error):
        failureHandler(
          (error as? FlutterError)
            ?? flutterError(NativeErrorCode.recordingError, error.localizedDescription)
        )
      }
    }
  }

  private func terminalRecordingError(screenError: Error?) -> Error? {
    if let screenError {
      return screenError
    }

    return pendingSeparateCameraFailure
  }

  private func handleSeparateCameraRecorderFailure(_ error: FlutterError) {
    runOnMainIfNeeded(reason: "cameraRecorder.onFailure", category: "Facade") { [weak self] in
      guard let self else { return }
      guard self.shouldRecordSeparateCameraAsset else { return }
      guard self.pendingSeparateCameraFailure == nil else { return }

      NativeLogger.e(
        "Facade",
        "Separate camera recording failed",
        context: [
          "state": "\(self.state)",
          "error": error.message ?? error.code,
        ])

      self.pendingSeparateCameraFailure = error

      switch self.state {
      case .starting:
        if self.capture.currentOutputURL != nil || self.capture.isRecording {
          self.capture.stop()
        } else {
          self.finishStartWithError(error)
        }
      case .recording, .paused:
        self.beginStoppingCapture()
      case .stopping, .idle:
        break
      }
    }
  }

  private func resetOverlayUpdateDeduper() {
    overlayUpdateDeduper.reset()
  }

  private func updateCursorVisibility() {
    let shouldShow =
      prefs.cursorLinked
      ? (isActivelyRecording && effectiveCursorEnabledForRecording)
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
    guard state == .starting || isRecordingSessionActive else { return }

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
    guard let micId = prefs.audioDeviceId, !micId.isEmpty else {
      micLevelMonitor.stop(emitZero: true)
      return
    }

    guard state == .idle || !hasReceivedRecordingMicrophoneLevel else {
      micLevelMonitor.stop(emitZero: resetMeter)
      return
    }

    micLevelMonitor.start(deviceID: micId) { [weak self] sample in
      self?.forwardMicrophoneLevel(sample, source: .idleMonitor)
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
    CaptureDestinationDiagnostics.url(for: activeRecordingProjectRoot)
  }

  private func preflightCaptureDestination(_ url: URL, allowLowStorageBypass: Bool) throws {
    let targetURL = diskSpaceLookupURL(for: url)
    let bytes = availableDiskSpaceBytes(at: url)
    let bundleIdentifier = Bundle.main.bundleIdentifier
    let bypassEnabled = CaptureDestinationPreflightPolicy.shouldBypassLowStorageCheck(
      requested: allowLowStorageBypass,
      bundleIdentifier: bundleIdentifier
    )
    let decision = CaptureDestinationPreflightPolicy.decision(
      availableBytes: bytes,
      requestedBypass: allowLowStorageBypass,
      bundleIdentifier: bundleIdentifier
    )

    NativeLogger.i(
      "Facade", "Capture destination disk preflight",
      context: [
        "path": targetURL.path,
        "availableBytes": bytes ?? -1,
        "warningThresholdBytes": StorageInfoProvider.warningThresholdBytes,
        "criticalThresholdBytes": StorageInfoProvider.criticalThresholdBytes,
        "requestedBypass": allowLowStorageBypass,
        "bypassEnabled": bypassEnabled,
      ])

    if allowLowStorageBypass && !bypassEnabled {
      NativeLogger.w(
        "Facade", "Ignoring low storage bypass request in production build",
        context: [
          "bundleID": bundleIdentifier ?? "unknown"
        ])
    }

    if bypassEnabled {
      NativeLogger.w(
        "Facade", "Bypassing low storage capture preflight for non-production build",
        context: [
          "path": targetURL.path,
          "availableBytes": bytes ?? -1,
        ])
      return
    }

    switch decision {
    case .proceed:
      return
    case .noAvailableSpace:
      throw flutterError(
        NativeErrorCode.outputUrlError,
        "Capture destination has no available disk space"
      )
    case .belowCriticalThreshold:
      throw flutterError(
        NativeErrorCode.outputUrlError,
        "Capture destination free space is below the minimum required to start recording"
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
    StorageInfoProvider.availableCapacity(for: url)
  }

  private func beginStoppingCapture() {
    guard state == .recording || state == .paused else { return }
    state = .stopping
    stateAsStr()
    applyIndicatorState()
    capture.stop()
  }

  private func drainPendingStopIfNeeded() {
    guard pendingStop, !isPauseResumeMutationInFlight else { return }
    beginStoppingCapture()
  }

  private func applyIndicatorState() {
    let configuration = makeIndicatorConfiguration()
    indicator.setState(
      configuration.state,
      pinned: prefs.indicatorPinned,
      onPauseTapped: configuration.onPauseTapped,
      onStopTapped: configuration.onStopTapped,
      onResumeTapped: configuration.onResumeTapped,
      elapsedProvider: configuration.elapsedProvider
    )
  }

  private func makeIndicatorConfiguration() -> IndicatorConfiguration {
    IndicatorConfiguration(
      state: currentIndicatorState(),
      onPauseTapped: capture.canPauseResume
        ? { [weak self] in self?.onIndicatorPauseTapped?() }
        : nil,
      onStopTapped: { [weak self] in self?.onIndicatorStopTapped?() },
      onResumeTapped: { [weak self] in self?.onIndicatorResumeTapped?() },
      elapsedProvider: { [weak self] in self?.formattedElapsed() ?? "00:00:00" }
    )
  }

  private func currentIndicatorState() -> IndicatorState {
    switch state {
    case .recording:
      return .recording
    case .paused:
      return .paused
    case .stopping:
      return .stopping
    case .idle, .starting:
      return .hidden
    }
  }

#if DEBUG
  struct IndicatorDebugConfiguration {
    let state: IndicatorState
    let onPauseTapped: (() -> Void)?
    let onStopTapped: (() -> Void)?
    let onResumeTapped: (() -> Void)?
  }

  func _testSetRecorderState(_ state: RecorderState) {
    self.state = state
  }

  func _testCurrentIndicatorState() -> IndicatorState {
    currentIndicatorState()
  }

  func _testIndicatorConfiguration() -> IndicatorDebugConfiguration {
    let configuration = makeIndicatorConfiguration()
    return IndicatorDebugConfiguration(
      state: configuration.state,
      onPauseTapped: configuration.onPauseTapped,
      onStopTapped: configuration.onStopTapped,
      onResumeTapped: configuration.onResumeTapped
    )
  }
#endif

  private func resolvePauseResumeFailure(_ error: Error) {
    let flutterFailure =
      (error as? FlutterError)
      ?? flutterError(NativeErrorCode.recordingError, error.localizedDescription)
    pauseResult?(flutterFailure)
    resumeResult?(flutterFailure)
    pauseResult = nil
    resumeResult = nil
    isPauseResumeMutationInFlight = false
  }

  private func resolvePauseResumeSuccessIfNeeded() {
    pauseResult?(nil)
    resumeResult?(nil)
    pauseResult = nil
    resumeResult = nil
    isPauseResumeMutationInFlight = false
  }

  private func completePausedTransition() {
    resetOverlayUpdateDeduper()
    recordedDurationTracker.pause()
    state = .paused
    stateAsStr()
    resolvePauseResumeSuccessIfNeeded()
    applyIndicatorState()

    if camera.isShowing && effectiveOverlayEnabledForRecording {
      camera.setRecordingHighlight(enabled: false)
    }

    updateOverlayVisibility()
    updateCursorVisibility()

    if let sessionId = activeRecordingWorkflowSessionId {
      onRecordingPaused?(sessionId)
    }

    drainPendingStopIfNeeded()
  }

  private func completeResumedTransition() {
    resetOverlayUpdateDeduper()
    recordedDurationTracker.resume()
    state = .recording
    stateAsStr()
    resolvePauseResumeSuccessIfNeeded()
    applyIndicatorState()

    if camera.isShowing && effectiveOverlayEnabledForRecording {
      camera.setRecordingHighlight(enabled: prefs.overlayHighlight)
    }

    updateOverlayVisibility()
    updateCursorVisibility()

    if let sessionId = activeRecordingWorkflowSessionId {
      onRecordingResumed?(sessionId)
    }

    drainPendingStopIfNeeded()
  }

  private func completeRecordingLifecycle(
    finalURL: URL?,
    error: Error?,
    wasStarting: Bool,
    pendingStartResult: FlutterResult?,
    completion: FlutterResult?,
    mode: RecordingCompletionMode = .ready
  ) {
    if let error {
      resolvePauseResumeFailure(error)
    } else {
      resolvePauseResumeSuccessIfNeeded()
    }

    pendingStop = false
    resetOverlayUpdateDeduper()
    state = .idle
    stateAsStr()
    hasReceivedRecordingMicrophoneLevel = false
    refreshMicrophoneLevelMonitoring(resetMeter: false)
    recordedDurationTracker.reset()
    pendingMetadata = nil
    pendingCameraRecordingSession = nil
    currentCaptureDisplayID = nil
    resetRecordingSessionSuppressions()

    applyIndicatorState()

    updateOverlayVisibility()
    updateCursorVisibility()

    onRecordingStateChanged?(false)

    if let error {
      if let projectRoot = activeRecordingProjectRoot {
        updateProjectManifestStatus(.failed, projectRoot: projectRoot)
      }
      if let sessionId = activeRecordingWorkflowSessionId {
        onRecordingFailed?([
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
        "Facade",
        "Recording finished with error",
        context: ["error": error.localizedDescription]
      )
      completion?(flutterError(NativeErrorCode.recordingError, error.localizedDescription))
      activeRecordingProjectRoot = nil
      activeRecordingWorkflowSessionId = nil
      cancelRequestedDuringStart = false
      return
    }

    switch mode {
    case .ready:
      if let projectPath = activeRecordingProjectRoot?.path,
        let sessionId = activeRecordingWorkflowSessionId
      {
        NativeLogger.i(
          "Facade",
          "Triggering onRecordingFinalized callback",
          context: ["projectPath": projectPath]
        )
        onRecordingFinalized?(sessionId, projectPath)
      }

      NativeLogger.i(
        "Facade",
        "Recording finished successfully",
        context: [
          "projectPath": activeRecordingProjectRoot?.path ?? "nil",
          "screenPath": finalURL?.path ?? "nil",
        ]
      )
      completion?(activeRecordingProjectRoot?.path)
    case .cancelled:
      NativeLogger.i(
        "Facade",
        "Recording cancelled before finalize completed",
        context: [
          "projectPath": activeRecordingProjectRoot?.path ?? "nil",
          "screenPath": finalURL?.path ?? "nil",
        ]
      )
      completion?(nil)
    }
    activeRecordingProjectRoot = nil
    activeRecordingWorkflowSessionId = nil
    cancelRequestedDuringStart = false
  }

  private func setCaptureBackend(_ backend: CaptureBackend) {
    self.capture = backend
    resetOverlayUpdateDeduper()
    self.capture.onMicrophoneLevel = { [weak self] sample in
      self?.forwardMicrophoneLevel(sample, source: .recordingBackend)
    }

    // Bridge backend callbacks into the facade state machine.
    self.capture.onStarted = { [weak self] url in
      guard let self else { return }
      let visibleProjectPath = self.activeRecordingProjectRoot?.path ?? url.path

      self.resetOverlayUpdateDeduper()
      self.state = .recording
      self.recordedDurationTracker.start()
      self.stateAsStr()
      self.refreshMicrophoneLevelMonitoring(resetMeter: false)

      // Write metadata sidecar when recording starts
      self.writeMetadataSidecar()
      self.writeCameraMetadataSidecarIfNeeded()

      self.onRecordingStateChanged?(true)
      if let sessionId = self.activeRecordingWorkflowSessionId {
        self.onRecordingStarted?(sessionId)
      }

      self.applyIndicatorState()

      // Only update recording-time visual state; don't rebuild the window here.
      if self.camera.isShowing && self.effectiveOverlayEnabledForRecording {
        self.camera.setRecordingHighlight(enabled: self.prefs.overlayHighlight)
      }

      self.updateOverlayVisibility()

      self.updateCursorVisibility()

      self.startResult?(visibleProjectPath)
      self.startResult = nil

      self.drainPendingStopIfNeeded()
    }

    self.capture.onPaused = { [weak self] in
      guard let self else { return }
      guard self.shouldRecordSeparateCameraAsset else {
        self.completePausedTransition()
        return
      }

      self.cameraRecorder.pause { result in
        switch result {
        case .success:
          self.completePausedTransition()
        case .failure(let error):
          self.resolvePauseResumeFailure(error)
        }
      }
    }

    self.capture.onResumed = { [weak self] in
      guard let self else { return }
      guard self.shouldRecordSeparateCameraAsset else {
        self.completeResumedTransition()
        return
      }

      self.cameraRecorder.resume { result in
        switch result {
        case .success:
          self.completeResumedTransition()
        case .failure(let error):
          self.resolvePauseResumeFailure(error)
        }
      }
    }

    self.capture.onFinished = { [weak self] url, error in
      guard let self else { return }
      let terminalError = self.terminalRecordingError(screenError: error)

      NativeLogger.i(
        "Facade", "Backend onFinished called",
        context: [
          "url": url?.path ?? "nil",
          "hasError": terminalError != nil,
          "error": terminalError?.localizedDescription ?? "nil",
        ])

      let pendingStartResult = self.startResult
      let wasStarting = self.state == .starting
      if wasStarting {
        self.startResult = nil
      }

      self.recordedDurationTracker.stop()

      let completion = self.stopResult
      self.stopResult = nil

      let finalizeWithCameraResult: (CameraRecordingResult?) -> Void = { cameraResult in
        var finalURL: URL? = url
        var completionMode: RecordingCompletionMode = .ready
        let cancelledDuringStart = self.cancelRequestedDuringStart
        if let projectRoot = self.activeRecordingProjectRoot {
          if cancelledDuringStart {
            completionMode = .cancelled
            let cancellationDisposition = self.cancellationDisposition(for: projectRoot)

            switch cancellationDisposition {
            case .deleteProject:
              let didDelete = self.recordingStore.deleteProject(projectRootURL: projectRoot)
              if !didDelete {
                self.updateProjectManifestStatus(.cancelled, projectRoot: projectRoot)
                finalURL = url
              } else {
                finalURL = nil
              }
            case .markCancelled:
              self.updateProjectManifestStatus(.finalizing, projectRoot: projectRoot)
              if let rawURL = url {
                self.updateMetadataSidecarOnFinish(
                  projectRoot: projectRoot,
                  cameraResult: cameraResult,
                  publishedScreenURL: rawURL
                )
                finalURL = rawURL
              } else {
                finalURL = nil
              }
              self.updateProjectManifestStatus(.cancelled, projectRoot: projectRoot)
            }
          } else if let rawURL = url {
            self.updateProjectManifestStatus(.finalizing, projectRoot: projectRoot)
            self.updateMetadataSidecarOnFinish(
              projectRoot: projectRoot,
              cameraResult: cameraResult,
              publishedScreenURL: rawURL
            )
            self.updateProjectManifestStatus(.ready, projectRoot: projectRoot)
            finalURL = rawURL
          } else {
            finalURL = nil
          }
        }

        self.completeRecordingLifecycle(
          finalURL: finalURL,
          error: terminalError,
          wasStarting: wasStarting,
          pendingStartResult: pendingStartResult,
          completion: completion,
          mode: completionMode
        )
      }

      if let terminalError {
        if self.pendingSeparateCameraFailure != nil {
          self.completeRecordingLifecycle(
            finalURL: nil,
            error: terminalError,
            wasStarting: wasStarting,
            pendingStartResult: pendingStartResult,
            completion: completion
          )
          return
        }

        if self.shouldRecordSeparateCameraAsset {
          self.cameraRecorder.stop { result in
            switch result {
            case .success(let cameraResult):
              finalizeWithCameraResult(cameraResult)
            case .failure(let cameraError):
              NativeLogger.w(
                "Facade",
                "Camera recorder stop failed during screen failure fallback",
                context: ["error": cameraError.localizedDescription]
              )
              self.completeRecordingLifecycle(
                finalURL: nil,
                error: terminalError,
                wasStarting: wasStarting,
                pendingStartResult: pendingStartResult,
                completion: completion
              )
            }
          }
        } else {
          self.completeRecordingLifecycle(
            finalURL: nil,
            error: terminalError,
            wasStarting: wasStarting,
            pendingStartResult: pendingStartResult,
            completion: completion
          )
        }
        return
      }

      guard self.shouldRecordSeparateCameraAsset else {
        finalizeWithCameraResult(nil)
        return
      }

      self.cameraRecorder.stop { result in
        switch result {
        case .success(let cameraResult):
          finalizeWithCameraResult(cameraResult)
        case .failure(let cameraError):
          NativeLogger.e(
            "Facade",
            "Camera recorder finalize failed during separate-camera recording",
            context: ["error": cameraError.localizedDescription]
          )
          self.completeRecordingLifecycle(
            finalURL: nil,
            error: cameraError,
            wasStarting: wasStarting,
            pendingStartResult: pendingStartResult,
            completion: completion
          )
        }
      }
    }
  }

  /// Writes the metadata sidecar file when recording starts.
  private func writeMetadataSidecar() {
    guard let metadata = pendingMetadata else {
      NativeLogger.w("Facade", "No pending metadata to write")
      return
    }
    guard let projectRoot = activeRecordingProjectRoot else {
      NativeLogger.w("Facade", "No active recording project to write metadata into")
      return
    }

    let metaURL = RecordingProjectPaths.screenMetadataURL(for: projectRoot)
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

  private func writeCameraMetadataSidecarIfNeeded() {
    guard let session = pendingCameraRecordingSession else { return }

    do {
      try session.stubMetadata().write(to: session.metadataURL)
      NativeLogger.d(
        "Facade",
        "Wrote camera metadata sidecar",
        context: ["path": session.metadataURL.lastPathComponent]
      )
    } catch {
      NativeLogger.e(
        "Facade",
        "Failed to write camera metadata sidecar",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func cameraCaptureInfo(
    from result: CameraRecordingResult,
    screenRawURL _: URL
  ) -> RecordingMetadata.CameraCaptureInfo {
    RecordingMetadata.CameraCaptureInfo(
      mode: .separateCameraAsset,
      enabled: true,
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      deviceId: result.metadata.deviceId,
      mirroredRaw: result.metadata.mirroredRaw,
      nominalFrameRate: result.metadata.nominalFrameRate,
      dimensions: result.metadata.dimensions.map {
        RecordingMetadata.Dimensions(width: $0.width, height: $0.height)
      },
      segments: result.metadata.segments
    )
  }

  /// Updates the metadata sidecar with end timestamp when recording finishes.
  private func updateMetadataSidecarOnFinish(
    projectRoot: URL,
    cameraResult: CameraRecordingResult?,
    publishedScreenURL: URL
  ) {
    let metaURL = RecordingProjectPaths.screenMetadataURL(for: projectRoot)

    // Read existing metadata and update with end timestamp
    do {
      var metadata = try RecordingMetadata.read(from: metaURL)
      metadata = metadata.withEndTimestamp()
      metadata.screen.segments = capture.recordedScreenSegments
      if let cameraResult {
        metadata.camera = cameraCaptureInfo(from: cameraResult, screenRawURL: publishedScreenURL)
      } else if shouldRecordSeparateCameraAsset {
        metadata.camera = nil
        metadata.editorSeed.cameraVisible = false
      }
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

  private func updateProjectManifestStatus(
    _ status: RecordingProjectStatus,
    projectRoot: URL
  ) {
    let manifestURL = RecordingProjectPaths.manifestURL(for: projectRoot)
    guard var manifest = try? RecordingProjectManifest.read(from: manifestURL) else {
      NativeLogger.w(
        "Facade",
        "Could not update recording project manifest status",
        context: ["path": manifestURL.path, "status": status.rawValue]
      )
      return
    }

    manifest.updateStatus(status)
    do {
      try manifest.write(to: manifestURL)
    } catch {
      NativeLogger.w(
        "Facade",
        "Failed writing recording project manifest status",
        context: [
          "path": manifestURL.path,
          "status": status.rawValue,
          "error": error.localizedDescription,
        ]
      )
    }
  }

  private enum RecordingCompletionMode {
    case ready
    case cancelled
  }

  private enum RecordingCancellationDisposition {
    case deleteProject
    case markCancelled
  }

  private func cancellationDisposition(for projectRoot: URL) -> RecordingCancellationDisposition {
    RecordingProjectPaths.hasDurableCaptureArtifacts(in: projectRoot)
      ? .markCancelled
      : .deleteProject
  }

#if DEBUG
  func _testBuildCaptureStartConfig(
    target: CaptureTarget,
    frameRate: Int = 30,
    systemAudioEnabled: Bool = false,
    outputURL: URL = URL(fileURLWithPath: "/tmp/recording.mov"),
    effectiveOverlayID: CGWindowID? = nil
  ) -> CaptureStartConfig {
    makeCaptureStartConfig(
      target: target,
      frameRate: frameRate,
      outputURL: { outputURL },
      effectiveOverlayID: effectiveOverlayID,
      systemAudioEnabled: systemAudioEnabled
    )
  }

  func _testUpdateMetadataSidecarOnFinish(
    projectRoot: URL,
    cameraResult: CameraRecordingResult?,
    publishedScreenURL: URL
  ) {
    updateMetadataSidecarOnFinish(
      projectRoot: projectRoot,
      cameraResult: cameraResult,
      publishedScreenURL: publishedScreenURL
    )
  }

  func _testShouldSuppressOverlayWindowDuringCapture() -> Bool {
    shouldSuppressOverlayWindowDuringCapture
  }

  func _testOverlayWindowIDForCapture(liveOverlayWindowID: CGWindowID?) -> CGWindowID? {
    overlayWindowIDForCapture(liveOverlayWindowID: liveOverlayWindowID)
  }

  func _testSetCaptureBackend(_ backend: CaptureBackend) {
    setCaptureBackend(backend)
  }

  func _testSetAudioDeviceId(_ id: String?) {
    prefs.audioDeviceId = id
  }

  func _testRefreshMicrophoneLevelMonitoring(resetMeter: Bool) {
    refreshMicrophoneLevelMonitoring(resetMeter: resetMeter)
  }

  func _testSyncOverlayWindowIntoCaptureIfNeeded() {
    syncOverlayWindowIntoCaptureIfNeeded()
  }

  func _testSanitizedCameraParamsForExport(
    _ params: CameraCompositionParams?,
    cameraPath: String?
  ) -> CameraCompositionParams? {
    exportSanitizedCameraParams(params, cameraPath: cameraPath)
  }

  func _testResolveTargetSize(
    sourceSize: CGSize,
    layout: String,
    resolution: String
  ) -> CGSize {
    resolveTargetSize(
      sourceSize: sourceSize,
      layout: layout,
      resolution: resolution
    )
  }

  func _testHandleCameraRecorderBeginResult(
    _ result: Result<Void, Error>,
    beginCapture: @escaping () -> Void,
    onFailure: @escaping (FlutterError) -> Void
  ) {
    handleCameraRecorderBeginResult(
      result,
      beginCapture: beginCapture,
      onFailure: onFailure
    )
  }

  func _testRunOverlayUITransitionOnMain(
    file: String = #file,
    line: Int = #line,
    operation: @escaping (Bool) -> Void
  ) {
    runOverlayUITransitionOnMain(reason: "testOverlayUITransition", file: file, line: line) {
      operation(Thread.isMainThread)
    }
  }

  func _testHandleSeparateCameraRecorderFailure(_ error: FlutterError) {
    handleSeparateCameraRecorderFailure(error)
  }

  func _testPendingSeparateCameraFailureCode() -> String? {
    pendingSeparateCameraFailure?.code
  }

  func _testTerminalRecordingError(screenError: Error?) -> Error? {
    terminalRecordingError(screenError: screenError)
  }

  func _testCancellationDisposition(projectRoot: URL) -> String {
    switch cancellationDisposition(for: projectRoot) {
    case .deleteProject:
      return "delete"
    case .markCancelled:
      return "cancelled"
    }
  }
#endif

  private var isActivelyRecording: Bool {
    state == .recording
  }

  private var isRecordingSessionActive: Bool {
    state == .recording || state == .paused
  }

  private func isShowingRecordingLinkedVisuals() -> Bool {
    state == .starting || state == .recording
  }

  func canClearCachedRecordings() -> Bool {
    CachedRecordingsCleanupPolicy.canClear(recorderState: state)
  }

  func clearCachedRecordings() -> Int {
    let deletedCount = recordingStore.deleteAll()
    NativeLogger.i(
      "Facade", "Cleared cached recordings",
      context: ["deletedCount": deletedCount]
    )
    return deletedCount
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
    case .paused:
      stateAsString = "paused"
    case .stopping:
      stateAsString = "stopping"
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
