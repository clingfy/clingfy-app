import AVFoundation

/// Dedicated AVCaptureSession that meters microphone level at ~15 fps.
/// macOS-platform (AVCaptureSession + audio output delegate → WASAPI metering on
/// Windows — see windows-port-inventory §7).
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
