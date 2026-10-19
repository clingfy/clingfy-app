import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import FlutterMacOS

/// What `CameraRecorder` needs from the capture graph.
///
/// Exists so the recorder can be driven without a camera. Three defensive
/// paths shipped untested for want of this seam — the readiness guard, the
/// unwind after a refused start, and the start timeout — and a regression in
/// the second of those escaped both a green suite and a green build, because
/// nothing could put the recorder into the state they guard.
///
/// Note that `startOutputRecording` is here rather than the underlying
/// `AVCaptureMovieFileOutput`: exposing the output would leave its start and
/// stop unfakeable, which are exactly the calls that raise, hang, and need
/// testing.
protocol CameraCaptureCoordinating: AnyObject {
  /// Whether the capture session is actually running.
  var isSessionRunning: Bool { get }

  /// Whether the movie output has a live video connection to record from.
  var hasActiveVideoConnection: Bool { get }

  /// Whether the movie output currently believes it is recording.
  var isOutputRecording: Bool { get }

  func acquireRecording(deviceID: String?) throws
  func releaseRecording()
  func setMirrored(_ mirrored: Bool)

  /// Starts a file recording, throwing rather than raising if the capture
  /// graph refuses. See `AVCaptureMovieFileOutputExceptionBridge`.
  func startOutputRecording(
    to url: URL,
    delegate: AVCaptureFileOutputRecordingDelegate
  ) throws

  func stopOutputRecording()
}

final class CameraCaptureCoordinator: NSObject, CameraCaptureCoordinating {
  enum StreamUse: Hashable {
    case preview
    case recording
  }

  private let session = AVCaptureSession()
  private let movieOutput = AVCaptureMovieFileOutput()
  private var videoDataOutput: AVCaptureVideoDataOutput?
  private var previewLayers = NSHashTable<AVCaptureVideoPreviewLayer>.weakObjects()
  private var input: AVCaptureDeviceInput?
  private var activeUses: Set<StreamUse> = []
  private var sampleBufferHandler: ((CMSampleBuffer) -> Void)?

  private(set) var currentDeviceID: String?
  private(set) var isMirrored: Bool = true

  override init() {
    super.init()
    session.sessionPreset = .high
    if session.canAddOutput(movieOutput) {
      session.addOutput(movieOutput)
    }
  }

  var recordingOutput: AVCaptureMovieFileOutput {
    movieOutput
  }

  /// Whether the capture session is actually running.
  ///
  /// `startRunning()` does not report failure: on a device that was just
  /// attached or switched, the session can decline to come up and leave this
  /// false. Starting a recording in that state makes AVFoundation raise, so
  /// callers check this first.
  var isSessionRunning: Bool {
    session.isRunning
  }

  /// Whether the movie output has a live video connection to record from.
  ///
  /// A session can be running while the output is not yet connected — the
  /// window right after a device change — which is the other state that makes
  /// `startRecording(to:)` raise.
  var hasActiveVideoConnection: Bool {
    guard let connection = movieOutput.connection(with: .video) else { return false }
    return connection.isActive && connection.isEnabled
  }

  var isOutputRecording: Bool {
    movieOutput.isRecording
  }

  /// Routed through the exception bridge because
  /// `startRecordingToOutputFileURL:` raises rather than returning an error,
  /// and Swift cannot catch an Objective-C raise — it reaches the terminate
  /// handler and aborts the process.
  func startOutputRecording(
    to url: URL,
    delegate: AVCaptureFileOutputRecordingDelegate
  ) throws {
    try AVCaptureMovieFileOutputExceptionBridge.startRecording(
      output: movieOutput,
      outputURL: url,
      recordingDelegate: delegate
    )
  }

  func stopOutputRecording() {
    movieOutput.stopRecording()
  }

  var selectedDevice: AVCaptureDevice? {
    input?.device
  }

  var nominalFrameRate: Double? {
    if let minDuration = selectedDevice?.activeVideoMinFrameDuration,
      minDuration.isNumeric,
      minDuration.seconds > 0
    {
      return 1.0 / minDuration.seconds
    }

    return selectedDevice?.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
  }

  var videoDimensions: CMVideoDimensions? {
    selectedDevice?.activeFormat.formatDescription.dimensions
  }

  func acquirePreview(deviceID: String?) throws {
    try ensureConfigured(deviceID: deviceID)
    activeUses.insert(.preview)
    startRunningIfNeeded()
  }

  #if DEBUG
    /// Test-only: mark a recording active without a camera device.
    func _testSetRecordingActive(_ active: Bool) {
      if active { activeUses.insert(.recording) } else { releaseRecording() }
    }

    /// Test-only: whether the chroma-key frame output is attached.
    var _testHasVideoDataOutput: Bool { videoDataOutput != nil }
  #endif

  func releasePreview() {
    activeUses.remove(.preview)
    stopRunningIfIdle()
  }

  func acquireRecording(deviceID: String?) throws {
    try ensureConfigured(deviceID: deviceID)
    activeUses.insert(.recording)
    startRunningIfNeeded()
  }

  func releaseRecording() {
    activeUses.remove(.recording)
    // A chroma-key output left attached for the recording's sake (see
    // configureVideoDataOutput) can go now that nothing is recording.
    if sampleBufferHandler == nil { configureVideoDataOutput(enabled: false) }
    stopRunningIfIdle()
  }

  /// The one preview layer, created once and handed out again on every show.
  ///
  /// A new `AVCaptureVideoPreviewLayer(session:)` adds a connection to the
  /// running session, and doing that while the movie file output is recording
  /// stops the recording ("Recording Stopped", flagged as a successful finish,
  /// so nothing noticed). On resume the overlay is shown again AFTER the camera
  /// segment has started, so every paused camera take recorded about 0.4s
  /// after its first resume and nothing more. Reusing the layer adds nothing to
  /// the session. Only `CameraOverlay` shows a preview, one at a time, and it
  /// removes the layer from its window when hidden, so one layer is enough.
  private var sharedPreviewLayer: AVCaptureVideoPreviewLayer?

  func makePreviewLayer(videoGravity: AVLayerVideoGravity = .resizeAspectFill) -> AVCaptureVideoPreviewLayer {
    let layer = sharedPreviewLayer ?? AVCaptureVideoPreviewLayer(session: session)
    sharedPreviewLayer = layer
    layer.videoGravity = videoGravity
    previewLayers.add(layer)
    applyMirror(to: layer)
    return layer
  }

  func removePreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
    guard let layer else { return }
    previewLayers.remove(layer)
  }

  func setMirrored(_ mirrored: Bool) {
    isMirrored = mirrored
    updateMirrorOnConnections()
  }

  func setSampleBufferHandler(_ handler: ((CMSampleBuffer) -> Void)?) {
    sampleBufferHandler = handler
    configureVideoDataOutput(enabled: handler != nil)
  }

  private func ensureConfigured(deviceID: String?) throws {
    let requestedDevice =
      deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
      ?? AVCaptureDevice.default(for: .video)

    guard let requestedDevice else {
      throw flutterError(NativeErrorCode.noCamera, "")
    }

    if input?.device.uniqueID == requestedDevice.uniqueID {
      currentDeviceID = requestedDevice.uniqueID
      updateMirrorOnConnections()
      return
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    if let input {
      session.removeInput(input)
      self.input = nil
    }

    do {
      let newInput = try AVCaptureDeviceInput(device: requestedDevice)
      guard session.canAddInput(newInput) else {
        throw flutterError(NativeErrorCode.cameraInputError, "Cannot add camera input")
      }
      session.addInput(newInput)
      input = newInput
      currentDeviceID = requestedDevice.uniqueID
    } catch let error as FlutterError {
      throw error
    } catch {
      throw flutterError(NativeErrorCode.cameraInputError, error.localizedDescription)
    }

    if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
      session.addOutput(movieOutput)
    }

    updateMirrorOnConnections()
  }

  private func configureVideoDataOutput(enabled: Bool) {
    if enabled {
      if videoDataOutput == nil {
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.clingfy.camera.processing"))

        session.beginConfiguration()
        if session.canAddOutput(output) {
          session.addOutput(output)
          videoDataOutput = output
        }
        session.commitConfiguration()
      }
    } else if let output = videoDataOutput {
      // Removing an output reconfigures the session, and changing the session
      // while the movie output records stops the recording (the same failure
      // the shared preview layer fixes). With chroma key on, hiding the
      // overlay on pause and re-showing it after resume did exactly that. So
      // while recording, keep the output attached and idle: the handler is
      // nil, so frames are dropped, and re-enabling reuses it. It is removed
      // when the recording ends (releaseRecording).
      if activeUses.contains(.recording) {
        updateMirrorOnConnections()
        return
      }
      output.setSampleBufferDelegate(nil, queue: nil)
      session.beginConfiguration()
      session.removeOutput(output)
      videoDataOutput = nil
      session.commitConfiguration()
    }

    updateMirrorOnConnections()
  }

  private func startRunningIfNeeded() {
    guard !session.isRunning else { return }
    session.startRunning()
  }

  private func stopRunningIfIdle() {
    guard activeUses.isEmpty else { return }
    guard session.isRunning else { return }
    session.stopRunning()
  }

  private func updateMirrorOnConnections() {
    if let connection = movieOutput.connection(with: .video),
      connection.isVideoMirroringSupported
    {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
    }

    if let connection = videoDataOutput?.connection(with: .video),
      connection.isVideoMirroringSupported
    {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
    }

    let layers = previewLayers.allObjects
    for layer in layers {
      applyMirror(to: layer)
    }
  }

  private func applyMirror(to layer: AVCaptureVideoPreviewLayer) {
    if let connection = layer.connection, connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
      return
    }

    let flipX: CGFloat = isMirrored ? -1.0 : 1.0
    layer.setAffineTransform(CGAffineTransform(scaleX: flipX, y: 1.0))
  }
}

extension CameraCaptureCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    sampleBufferHandler?(sampleBuffer)
  }
}
