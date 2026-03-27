import AVFoundation
import AppKit

final class CapturePipeline: NSObject, AVCaptureFileOutputRecordingDelegate {
  private let queue = DispatchQueue(label: "com.clingfy.capture")
  private(set) var session: AVCaptureSession?
  private(set) var movieOutput: AVCaptureMovieFileOutput?
  var onStarted: ((URL) -> Void)?
  var onPaused: (() -> Void)?
  var onResumed: (() -> Void)?
  var onFinished: ((URL?, Error?) -> Void)?

  private let cursorRecorder = CursorRecorder()

  private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
  private var currentCaptureRect: CGRect?
  private var currentCursorRasterScale: Double = 1.0

  func start(
    displayID: CGDirectDisplayID,
    cropRect: CGRect?,
    quality: RecordingQuality,
    frameRate: Int,
    includeAudioDevice: AVCaptureDevice?,
    makeOutputURL: @escaping () throws -> URL
  ) {
    queue.async {
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

        // Persist capture geometry once the session start is confirmed.
        self.currentDisplayID = displayID
        self.currentCaptureRect = cropRect

        session.startRunning()
        movie.startRecording(to: url, recordingDelegate: self)
      } catch {
        self.finishStartError(code: "OUTPUT_URL_ERROR", msg: error.localizedDescription)
      }
    }
  }

  func stop() {
    queue.async { self.movieOutput?.stopRecording() }
  }

  func pause() {
    queue.async {
      guard let movieOutput = self.movieOutput, movieOutput.isRecording, !movieOutput.isRecordingPaused
      else { return }
      movieOutput.pauseRecording()
    }
  }

  func resume() {
    queue.async {
      guard let movieOutput = self.movieOutput, movieOutput.isRecordingPaused else { return }
      movieOutput.resumeRecording()
    }
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

  // MARK: delegate
  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    cursorRecorder.start(
      displayID: currentDisplayID,
      captureRect: currentCaptureRect,
      cursorRasterScale: currentCursorRasterScale
    )
    DispatchQueue.main.async {
      self.onStarted?(fileURL)
    }
  }

  func captureOutput(
    _ output: AVCaptureFileOutput,
    didPauseRecordingToOutputFileAt fileURL: URL,
    fromConnections connections: [AVCaptureConnection]
  ) {
    cursorRecorder.pause()
    DispatchQueue.main.async {
      self.onPaused?()
    }
  }

  func captureOutput(
    _ output: AVCaptureFileOutput,
    didResumeRecordingToOutputFileAt fileURL: URL,
    fromConnections connections: [AVCaptureConnection]
  ) {
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
    self.logFinalVideoInfoAVF(url: url)

    let cursorURL = url.deletingPathExtension().appendingPathExtension("cursor.json")

    cursorRecorder.stop(outputURL: cursorURL) { [weak self] in
      guard let self = self else { return }
      DispatchQueue.main.async {
        self.onFinished?(url, error)
      }
    }
  }
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
