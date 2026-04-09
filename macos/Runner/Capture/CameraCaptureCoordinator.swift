import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import FlutterMacOS

final class CameraCaptureCoordinator: NSObject {
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
    stopRunningIfIdle()
  }

  func makePreviewLayer(videoGravity: AVLayerVideoGravity = .resizeAspectFill) -> AVCaptureVideoPreviewLayer {
    let layer = AVCaptureVideoPreviewLayer(session: session)
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
