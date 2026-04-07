import AVFoundation
import AppKit
import QuartzCore

// Orchestrates export stages; camera-only pixel preprocessing stays in the pre-pass pipeline.
final class LetterboxExporter {
  private struct FrameContentMetrics {
    let totalPixels: Int
    let visiblePixels: Int
    let nonBlackVisiblePixels: Int

    var visibleRatio: Double {
      guard totalPixels > 0 else { return 0.0 }
      return Double(visiblePixels) / Double(totalPixels)
    }

    var nonBlackVisibleRatio: Double {
      guard visiblePixels > 0 else { return 0.0 }
      return Double(nonBlackVisiblePixels) / Double(visiblePixels)
    }
  }

  private struct FrameColorMetrics {
    let visiblePixels: Int
    let averageRed: Double
    let averageGreen: Double
    let averageBlue: Double
    let dominantRedRatio: Double
    let dominantGreenRatio: Double
    let dominantBlueRatio: Double
  }

  private let builder = CompositionBuilder()
  private let cameraPrepassPipeline = CameraStyledIntermediatePipeline()
  private let screenPrepassPipeline = ScreenZoomCursorIntermediatePipeline()
  private var currentSession: AVAssetExportSession?
  private var progressTimer: Timer?
  private var temporaryArtifacts: [URL] = []
  private var isCancelled = false
  private let validationSampleDimension = 64
  private let validationAlphaThreshold: UInt8 = 8
  private let validationNonBlackThreshold: UInt8 = 12

  func cancel() {
    isCancelled = true
    progressTimer?.invalidate()
    progressTimer = nil
    currentSession?.cancelExport()
    currentSession = nil
  }

  private func registerTemporaryArtifact(_ url: URL) {
    if !temporaryArtifacts.contains(url) {
      temporaryArtifacts.append(url)
    }
  }

  private func cleanupTemporaryArtifacts() {
    let fileManager = FileManager.default
    for url in Set(temporaryArtifacts) {
      if fileManager.fileExists(atPath: url.path) {
        try? fileManager.removeItem(at: url)
        NativeLogger.d(
          "Export",
          "Cleaned up temporary export artifact",
          context: ["path": url.path]
        )
      }
    }
    temporaryArtifacts.removeAll()
  }

  private func removeFileIfExists(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func formattedBackgroundColor(_ color: Int?) -> String {
    guard let color else { return "nil" }
    return String(format: "0x%08X", color)
  }

  private func validationSampleTime(for asset: AVAsset) -> CMTime {
    let seconds = asset.duration.seconds
    guard seconds.isFinite, seconds > 0 else { return .zero }
    return CMTime(seconds: min(1.0, seconds / 2.0), preferredTimescale: 600)
  }

  private func sampleFrameImage(asset: AVAsset) throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(
      width: validationSampleDimension,
      height: validationSampleDimension
    )
    return try generator.copyCGImage(at: validationSampleTime(for: asset), actualTime: nil)
  }

  private func orientedSize(for asset: AVAsset) -> CGSize? {
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }

  private func analyzeFrameContent(
    _ image: CGImage,
    ignoreTransparentPixels: Bool
  ) -> FrameContentMetrics? {
    let width = validationSampleDimension
    let height = validationSampleDimension
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    var metrics: FrameContentMetrics?
    buffer.withUnsafeMutableBytes { rawBuffer in
      guard
        let baseAddress = rawBuffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else {
        return
      }

      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let pixelBytes = rawBuffer.bindMemory(to: UInt8.self)

      var visiblePixels = 0
      var nonBlackVisiblePixels = 0

      for pixelIndex in 0..<(width * height) {
        let offset = pixelIndex * 4
        let alpha = pixelBytes[offset + 3]
        let isVisible = !ignoreTransparentPixels || alpha > validationAlphaThreshold
        if !isVisible {
          continue
        }

        visiblePixels += 1
        let red = pixelBytes[offset]
        let green = pixelBytes[offset + 1]
        let blue = pixelBytes[offset + 2]
        if max(red, max(green, blue)) > validationNonBlackThreshold {
          nonBlackVisiblePixels += 1
        }
      }

      metrics = FrameContentMetrics(
        totalPixels: width * height,
        visiblePixels: visiblePixels,
        nonBlackVisiblePixels: nonBlackVisiblePixels
      )
    }

    return metrics
  }

  private func analyzeFrameColorMetrics(
    _ image: CGImage,
    ignoreTransparentPixels: Bool
  ) -> FrameColorMetrics? {
    let width = validationSampleDimension
    let height = validationSampleDimension
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    buffer.withUnsafeMutableBytes { rawBuffer in
      guard
        let baseAddress = rawBuffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else {
        return
      }

      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var visiblePixels = 0
    var redDominantPixels = 0
    var greenDominantPixels = 0
    var blueDominantPixels = 0
    var redTotal = 0.0
    var greenTotal = 0.0
    var blueTotal = 0.0

    for pixelIndex in 0..<(width * height) {
      let offset = pixelIndex * 4
      let alpha = buffer[offset + 3]
      if ignoreTransparentPixels && alpha <= validationAlphaThreshold {
        continue
      }

      let red = Double(buffer[offset]) / 255.0
      let green = Double(buffer[offset + 1]) / 255.0
      let blue = Double(buffer[offset + 2]) / 255.0

      visiblePixels += 1
      redTotal += red
      greenTotal += green
      blueTotal += blue

      if Int(buffer[offset]) > Int(buffer[offset + 1]) + 20
        && Int(buffer[offset]) > Int(buffer[offset + 2]) + 20
      {
        redDominantPixels += 1
      }
      if Int(buffer[offset + 1]) > Int(buffer[offset]) + 20
        && Int(buffer[offset + 1]) > Int(buffer[offset + 2]) + 20
      {
        greenDominantPixels += 1
      }
      if Int(buffer[offset + 2]) > Int(buffer[offset]) + 20
        && Int(buffer[offset + 2]) > Int(buffer[offset + 1]) + 20
      {
        blueDominantPixels += 1
      }
    }

    guard visiblePixels > 0 else { return nil }

    return FrameColorMetrics(
      visiblePixels: visiblePixels,
      averageRed: redTotal / Double(visiblePixels),
      averageGreen: greenTotal / Double(visiblePixels),
      averageBlue: blueTotal / Double(visiblePixels),
      dominantRedRatio: Double(redDominantPixels) / Double(visiblePixels),
      dominantGreenRatio: Double(greenDominantPixels) / Double(visiblePixels),
      dominantBlueRatio: Double(blueDominantPixels) / Double(visiblePixels)
    )
  }

  private func croppedImageVariants(
    from image: CGImage,
    cropRect: CGRect,
    canvasSize: CGSize
  ) -> [CGImage] {
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let scaleX = CGFloat(image.width) / max(canvasSize.width, 1.0)
    let scaleY = CGFloat(image.height) / max(canvasSize.height, 1.0)

    return [false, true].compactMap { flipY in
      let sourceY = flipY ? (canvasSize.height - cropRect.maxY) : cropRect.minY
      let pixelRect = CGRect(
        x: cropRect.minX * scaleX,
        y: sourceY * scaleY,
        width: cropRect.width * scaleX,
        height: cropRect.height * scaleY
      ).integral.intersection(imageBounds)

      guard pixelRect.width >= 1.0, pixelRect.height >= 1.0 else { return nil }
      return image.cropping(to: pixelRect)
    }
  }

  private func bestMetrics(
    from image: CGImage,
    cropRect: CGRect?,
    canvasSize: CGSize,
    ignoreTransparentPixels: Bool
  ) -> FrameContentMetrics? {
    let candidateImages: [CGImage]
    if let cropRect {
      candidateImages = croppedImageVariants(
        from: image,
        cropRect: cropRect,
        canvasSize: canvasSize
      )
    } else {
      candidateImages = [image]
    }

    return candidateImages
      .compactMap { analyzeFrameContent($0, ignoreTransparentPixels: ignoreTransparentPixels) }
      .max(by: { lhs, rhs in
        lhs.nonBlackVisibleRatio < rhs.nonBlackVisibleRatio
      })
  }

  private func validateStyledCameraIntermediate(
    rawCameraAsset: AVAsset,
    styledCameraAsset: AVAsset,
    placementSourceRect: CGRect?
  ) -> NSError? {
    do {
      let rawImage = try sampleFrameImage(asset: rawCameraAsset)
      let styledImage = try sampleFrameImage(asset: styledCameraAsset)
      let styledCanvasSize = orientedSize(for: styledCameraAsset)
        ?? CGSize(width: styledImage.width, height: styledImage.height)

      guard
        let rawMetrics = analyzeFrameContent(rawImage, ignoreTransparentPixels: false),
        let styledMetrics = bestMetrics(
          from: styledImage,
          cropRect: placementSourceRect,
          canvasSize: styledCanvasSize,
          ignoreTransparentPixels: true
        )
      else {
        return makeAdvancedCameraExportError(
          stage: .styledIntermediateValidation,
          reason: "The camera export validator could not analyze the rendered frame."
        )
      }

      NativeLogger.d(
        "Export",
        "Styled camera validation metrics",
        context: [
          "rawVisibleRatio": rawMetrics.visibleRatio,
          "rawNonBlackRatio": rawMetrics.nonBlackVisibleRatio,
          "styledVisibleRatio": styledMetrics.visibleRatio,
          "styledNonBlackRatio": styledMetrics.nonBlackVisibleRatio,
        ]
      )

      guard rawMetrics.nonBlackVisibleRatio >= 0.05 else {
        return nil
      }

      if styledMetrics.visiblePixels == 0 || styledMetrics.nonBlackVisibleRatio < 0.01 {
        return makeAdvancedCameraExportError(
          stage: .styledIntermediateValidation,
          reason: "The styled camera intermediate rendered blank or black video.",
          context: [
            "rawNonBlackRatio": rawMetrics.nonBlackVisibleRatio,
            "styledVisibleRatio": styledMetrics.visibleRatio,
            "styledNonBlackRatio": styledMetrics.nonBlackVisibleRatio,
          ]
        )
      }

      return nil
    } catch {
      return makeAdvancedCameraExportError(
        stage: .styledIntermediateValidation,
        reason: "The camera export validator could not sample the styled intermediate.",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func validateFinalStyledCameraExport(
    styledCameraAsset: AVAsset,
    finalExportAsset: AVAsset,
    canvasSize: CGSize,
    cameraParams: CameraCompositionParams,
    placementSourceRect: CGRect?
  ) -> NSError? {
    let resolution = CameraLayoutResolver.effectiveFrame(
      canvasSize: canvasSize,
      params: cameraParams
    )
    guard resolution.shouldRender else { return nil }

    do {
      let styledImage = try sampleFrameImage(asset: styledCameraAsset)
      let finalImage = try sampleFrameImage(asset: finalExportAsset)
      let styledCanvasSize = orientedSize(for: styledCameraAsset)
        ?? CGSize(width: styledImage.width, height: styledImage.height)

      guard let styledMetrics = bestMetrics(
        from: styledImage,
        cropRect: placementSourceRect,
        canvasSize: styledCanvasSize,
        ignoreTransparentPixels: true
      ) else {
        return makeAdvancedCameraExportError(
          stage: .finalOutputValidation,
          reason: "The final export validator could not analyze the styled camera frame."
        )
      }

      guard styledMetrics.nonBlackVisibleRatio >= 0.05 else {
        return nil
      }

      let cropMetrics = croppedImageVariants(
        from: finalImage,
        cropRect: resolution.frame,
        canvasSize: canvasSize
      ).compactMap {
        analyzeFrameContent($0, ignoreTransparentPixels: false)
      }

      guard let bestCropMetrics = cropMetrics.max(by: { lhs, rhs in
        lhs.nonBlackVisibleRatio < rhs.nonBlackVisibleRatio
      }) else {
        return makeAdvancedCameraExportError(
          stage: .finalOutputValidation,
          reason: "The final export validator could not read the exported camera region."
        )
      }

      let requiredNonBlackRatio = max(0.01, styledMetrics.nonBlackVisibleRatio * 0.2)

      NativeLogger.d(
        "Export",
        "Final styled camera validation metrics",
        context: [
          "styledNonBlackRatio": styledMetrics.nonBlackVisibleRatio,
          "finalCropNonBlackRatio": bestCropMetrics.nonBlackVisibleRatio,
          "requiredNonBlackRatio": requiredNonBlackRatio,
        ]
      )

      guard bestCropMetrics.nonBlackVisibleRatio >= requiredNonBlackRatio else {
        return makeAdvancedCameraExportError(
          stage: .finalOutputValidation,
          reason: "The final exported camera region rendered blank or black video.",
          context: [
            "styledNonBlackRatio": styledMetrics.nonBlackVisibleRatio,
            "finalCropNonBlackRatio": bestCropMetrics.nonBlackVisibleRatio,
            "requiredNonBlackRatio": requiredNonBlackRatio,
          ]
        )
      }

      return nil
    } catch {
      return makeAdvancedCameraExportError(
        stage: .finalOutputValidation,
        reason: "The final export validator could not sample the exported file.",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func validateScreenPrepassIntermediate(
    rawScreenAsset: AVAsset,
    prepassScreenAsset: AVAsset
  ) -> NSError? {
    do {
      let rawImage = try sampleFrameImage(asset: rawScreenAsset)
      let prepassImage = try sampleFrameImage(asset: prepassScreenAsset)

      guard
        let rawContentMetrics = analyzeFrameContent(rawImage, ignoreTransparentPixels: false),
        let prepassContentMetrics = analyzeFrameContent(prepassImage, ignoreTransparentPixels: true),
        let rawColorMetrics = analyzeFrameColorMetrics(rawImage, ignoreTransparentPixels: false),
        let prepassColorMetrics = analyzeFrameColorMetrics(prepassImage, ignoreTransparentPixels: true)
      else {
        return makeScreenPrepassExportError(
          stage: .validation,
          reason: "The screen pre-pass validator could not analyze the rendered frame."
        )
      }

      NativeLogger.d(
        "Export",
        "Screen pre-pass validation metrics",
        context: [
          "rawNonBlackRatio": rawContentMetrics.nonBlackVisibleRatio,
          "prepassVisibleRatio": prepassContentMetrics.visibleRatio,
          "prepassNonBlackRatio": prepassContentMetrics.nonBlackVisibleRatio,
          "rawAverageRed": rawColorMetrics.averageRed,
          "rawAverageGreen": rawColorMetrics.averageGreen,
          "rawAverageBlue": rawColorMetrics.averageBlue,
          "rawDominantRedRatio": rawColorMetrics.dominantRedRatio,
          "rawDominantGreenRatio": rawColorMetrics.dominantGreenRatio,
          "rawDominantBlueRatio": rawColorMetrics.dominantBlueRatio,
          "prepassAverageRed": prepassColorMetrics.averageRed,
          "prepassAverageGreen": prepassColorMetrics.averageGreen,
          "prepassAverageBlue": prepassColorMetrics.averageBlue,
          "prepassDominantRedRatio": prepassColorMetrics.dominantRedRatio,
          "prepassDominantGreenRatio": prepassColorMetrics.dominantGreenRatio,
          "prepassDominantBlueRatio": prepassColorMetrics.dominantBlueRatio,
        ]
      )

      guard rawContentMetrics.nonBlackVisibleRatio >= 0.05 else {
        return nil
      }

      if prepassContentMetrics.visiblePixels == 0 || prepassContentMetrics.nonBlackVisibleRatio < 0.01 {
        return makeScreenPrepassExportError(
          stage: .validation,
          reason: "The screen pre-pass rendered blank or black video.",
          context: [
            "prepassVisibleRatio": prepassContentMetrics.visibleRatio,
            "prepassNonBlackRatio": prepassContentMetrics.nonBlackVisibleRatio,
          ]
        )
      }

      let hasSevereRedWash =
        rawColorMetrics.dominantRedRatio < 0.35
        && prepassColorMetrics.dominantRedRatio > 0.70
        && prepassColorMetrics.dominantGreenRatio < 0.20
        && prepassColorMetrics.dominantBlueRatio < 0.20
        && prepassColorMetrics.averageRed > rawColorMetrics.averageRed + 0.20
        && prepassColorMetrics.averageRed > prepassColorMetrics.averageGreen + 0.20
        && prepassColorMetrics.averageRed > prepassColorMetrics.averageBlue + 0.20

      if hasSevereRedWash {
        return makeScreenPrepassExportError(
          stage: .validation,
          reason: "The screen pre-pass rendered with a severe red color cast.",
          context: [
            "rawDominantRedRatio": rawColorMetrics.dominantRedRatio,
            "prepassDominantRedRatio": prepassColorMetrics.dominantRedRatio,
            "prepassDominantGreenRatio": prepassColorMetrics.dominantGreenRatio,
            "prepassDominantBlueRatio": prepassColorMetrics.dominantBlueRatio,
            "rawAverageRed": rawColorMetrics.averageRed,
            "prepassAverageRed": prepassColorMetrics.averageRed,
            "prepassAverageGreen": prepassColorMetrics.averageGreen,
            "prepassAverageBlue": prepassColorMetrics.averageBlue,
          ]
        )
      }

      return nil
    } catch {
      return makeScreenPrepassExportError(
        stage: .validation,
        reason: "The screen pre-pass validator could not sample the intermediate.",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func runExportSession(
    _ export: AVAssetExportSession,
    outputURL: URL,
    progressRange: ClosedRange<Double>,
    onProgress: ((Double) -> Void)?,
    logOutputInfo: Bool = false,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    self.currentSession = export

    let lower = progressRange.lowerBound
    let span = progressRange.upperBound - progressRange.lowerBound
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak export] _ in
      guard let export else { return }
      onProgress?(lower + (Double(export.progress) * span))
    }

    export.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.progressTimer?.invalidate()
        self?.progressTimer = nil
        self?.currentSession = nil

        switch export.status {
        case .completed:
          onProgress?(progressRange.upperBound)
          if logOutputInfo {
            self?.logExportedFileInfo(url: outputURL)
          }
          completion(.success(outputURL))

        case .cancelled:
          completion(
            .failure(
              NSError(
                domain: "Letterbox",
                code: -999,
                userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]
              )
            )
          )
        case .failed:
          completion(
            .failure(
              export.error
                ?? NSError(
                  domain: "Letterbox",
                  code: -3,
                  userInfo: [NSLocalizedDescriptionKey: "Export failed"]
                )
            )
          )
        default:
          completion(
            .failure(
              NSError(
                domain: "Letterbox",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Export ended in unexpected state \(export.status.rawValue)"]
              )
            )
          )
        }
      }
    }
  }

  func export(
    project: RecordingProjectRef,
    target: CGSize,
    padding: Double = 0,
    cornerRadius: Double = 0,
    backgroundColor: Int? = nil,
    backgroundImagePath: String? = nil,
    cursorSize: Double = 1.0,
    showCursor: Bool = true,
    zoomEnabled: Bool = false,
    zoomFactor: CGFloat = 1.5,
    followStrength: CGFloat = 0.15,
    fpsHint: Int32 = 60,
    outputURL: URL,
    format: String,
    codec: String,
    bitrate: String,
    fitMode: String? = nil,
    audioGainDb: Double = 0.0,
    audioVolumePercent: Double = 100.0,
    autoNormalizeOnExport: Bool = false,
    targetLoudnessDbfs: Double = -16.0,
    cameraParams: CameraCompositionParams? = nil,
    onProgress: ((Double) -> Void)? = nil,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    // Cancel any existing session
    cancel()
    isCancelled = false

    let mediaSources = project.mediaSources()
    let inputURL = mediaSources.screenVideoURL
    let cameraInputURL = mediaSources.cameraVideoURL

    let asset = AVAsset(url: inputURL)

    // Load cursor recording if needed (gracefully handle missing cursor file)
    var cursorRecording: CursorRecording?
    if showCursor {
      if let cursorDataURL = mediaSources.cursorDataURL,
        let data = try? Data(contentsOf: cursorDataURL),
        let recording = try? JSONDecoder().decode(CursorRecording.self, from: data)
      {
        cursorRecording = recording
        NativeLogger.d(
          "Export", "Loaded cursor data",
          context: ["frames": recording.frames.count, "sprites": recording.sprites.count])
      } else {
        // Cursor file missing - this is OK, we just proceed without cursor overlay
        NativeLogger.i(
          "Export", "Cursor data missing or invalid, proceeding without cursor overlay",
          context: ["expectedPath": mediaSources.cursorPath ?? "nil"])
      }
    }

    // Load manual segments
    var manualSegments: [ZoomTimelineSegment] = []
    var overriddenAutoIds: Set<String> = []

    if let manualURL = mediaSources.zoomManualURL,
      let data = try? Data(contentsOf: manualURL),
      let manualData = try? JSONDecoder().decode(ZoomManualData.self, from: data)
    {
      let allManual = manualData.segments
      overriddenAutoIds = Set(allManual.compactMap { $0.baseId })

      manualSegments = allManual
        .filter { $0.endMs > $0.startMs }  // exclude tombstones
        .map { ZoomTimelineSegment(startMs: $0.startMs, endMs: $0.endMs) }

      NativeLogger.d(
        "Export", "Loaded manual zoom segments",
        context: ["count": manualSegments.count, "overrides": overriddenAutoIds.count])
    }

    // Load auto segments from cursorRecording if available
    var autoSegments: [ZoomTimelineSegment] = []
    if let recording = cursorRecording {
      let duration = asset.duration.seconds
      let rawAuto = ZoomTimelineBuilder.buildSegments(
        cursorRecording: recording,
        durationSeconds: duration
      )

      // Filter out overridden auto segments
      autoSegments = rawAuto.enumerated().compactMap { (index, seg) in
        let id = "auto_\(index)"
        if overriddenAutoIds.contains(id) {
          return nil
        }
        return ZoomTimelineSegment(startMs: seg.startMs, endMs: seg.endMs)
      }

      NativeLogger.d(
        "Export", "Processed auto zoom segments",
        context: ["raw": rawAuto.count, "effective": autoSegments.count])
    }

    let effectiveSegments = (autoSegments + manualSegments).merged()

    var params = CompositionParams(
      targetSize: target,
      padding: padding,
      cornerRadius: cornerRadius,
      backgroundColor: backgroundColor,
      backgroundImagePath: backgroundImagePath,
      cursorSize: cursorSize,
      showCursor: showCursor,
      zoomEnabled: zoomEnabled,
      zoomFactor: zoomFactor,
      followStrength: followStrength,
      fpsHint: fpsHint,
      fitMode: fitMode,
      audioGainDb: audioGainDb,
      audioVolumePercent: audioVolumePercent
    )
    params.zoomSegments = effectiveSegments

    let resolvedAudioMix = resolveAudioMixControls(
      asset: asset,
      userGainDb: audioGainDb,
      userVolumePercent: audioVolumePercent,
      autoNormalizeOnExport: autoNormalizeOnExport,
      targetLoudnessDbfs: targetLoudnessDbfs
    )

    NativeLogger.i(
      "Export", "Export resolved",
      context: [
        "projectPath": project.rootURL.path,
        "input": inputURL.path,
        "output": outputURL.path,
        "target": "\(Int(target.width))x\(Int(target.height))",
        "fpsHint": fpsHint,
        "format": format,
        "codec": codec,
        "backgroundColor": formattedBackgroundColor(backgroundColor),
        "backgroundImagePath": backgroundImagePath ?? "nil",
        "hasCustomBackground": backgroundColor != nil || backgroundImagePath != nil,
      ])

    let shouldUseCameraPrepass = cameraPrepassPipeline.requiresPrepass(cameraParams: cameraParams)
    let shouldUseScreenPrepass = screenPrepassPipeline.requiresPrepass(
      cameraAssetURL: cameraInputURL,
      cameraParams: cameraParams,
      params: params,
      cursorRecording: cursorRecording
    )

    func pickPreset(for exportAsset: AVAsset) -> String {
      let compatible = Set(AVAssetExportSession.exportPresets(compatibleWith: exportAsset))

      func pick(_ candidates: [String]) -> String {
        for candidate in candidates where compatible.contains(candidate) {
          return candidate
        }
        return AVAssetExportPresetHighestQuality
      }

      let useHevc = codec == "hevc"
      if target.width >= 7680 || target.height >= 4320 {
        if #available(macOS 13.0, *) {
          return
            useHevc
            ? pick([
              "AVAssetExportPresetHEVC7680x4320",
              AVAssetExportPresetHEVCHighestQuality,
              AVAssetExportPresetHighestQuality,
            ])
            : pick([AVAssetExportPresetHighestQuality])
        }
        return
          useHevc
          ? pick([AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality])
          : pick([AVAssetExportPresetHighestQuality])
      } else if target.width >= 3840 || target.height >= 2160 {
        return
          useHevc
          ? pick([
            AVAssetExportPresetHEVC3840x2160,
            AVAssetExportPreset3840x2160,
            AVAssetExportPresetHEVCHighestQuality,
            AVAssetExportPresetHighestQuality,
          ])
          : pick([AVAssetExportPreset3840x2160, AVAssetExportPresetHighestQuality])
      } else if target.width >= 1920 || target.height >= 1080 {
        return
          useHevc
          ? pick([
            AVAssetExportPresetHEVC1920x1080,
            AVAssetExportPreset1920x1080,
            AVAssetExportPresetHEVCHighestQuality,
          ])
          : pick([AVAssetExportPreset1920x1080, AVAssetExportPresetHighestQuality])
      }

      return
        useHevc
        ? pick([AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality])
        : pick([AVAssetExportPresetHighestQuality])
    }

    func scaledProgress(
      _ progress: Double,
      into range: ClosedRange<Double>
    ) -> Double {
      let clamped = min(max(progress, 0.0), 1.0)
      return range.lowerBound + (clamped * (range.upperBound - range.lowerBound))
    }

    func beginFinalExport(
      resolvedScreenInputURL: URL,
      resolvedCameraInputURL: URL?,
      progressRange: ClosedRange<Double>,
      cameraAssetIsPreStyled: Bool,
      cameraPlacementSourceRect: CGRect?,
      screenSourceMode: CompositionBuilder.ScreenSourceMode
    ) {
      let screenAsset = AVAsset(url: resolvedScreenInputURL)
      let cameraAsset = resolvedCameraInputURL.map(AVAsset.init(url:))

      if CameraPlacementDebug.enabled {
        var context: [String: Any] = [
          "resolvedScreenInputURL": resolvedScreenInputURL.path,
          "resolvedCameraInputURL": resolvedCameraInputURL?.path ?? "nil",
          "cameraAssetIsPreStyled": cameraAssetIsPreStyled,
          "screenSourceMode": screenSourceMode.rawValue,
        ]
        context.merge(
          CameraPlacementDebug.sizeContext(prefix: "target", size: target),
          uniquingKeysWith: { _, new in new }
        )
        context.merge(
          CameraPlacementDebug.rectContext(
            prefix: "cameraPlacementSourceRect",
            rect: cameraPlacementSourceRect
          ),
          uniquingKeysWith: { _, new in new }
        )
        if let cameraParams {
          context["cameraLayoutPreset"] = cameraParams.layoutPreset.rawValue
          context["cameraSizeFactor"] = cameraParams.sizeFactor
          context["cameraZoomBehavior"] = cameraParams.zoomBehavior.rawValue
          context["cameraZoomScaleMultiplier"] = cameraParams.zoomScaleMultiplier
          context["cameraShape"] = cameraParams.shape.rawValue
          context["cameraShadowPreset"] = cameraParams.shadowPreset
          context.merge(
            CameraPlacementDebug.pointContext(
              prefix: "cameraNormalizedCanvasCenter",
              point: cameraParams.normalizedCanvasCenter
            ),
            uniquingKeysWith: { _, new in new }
          )
        }

        NativeLogger.d(
          "CameraPlacementDbg",
          "Final export camera request",
          context: context
        )
      }

      guard
        let comp = builder.buildExport(
          asset: screenAsset,
          cameraAsset: cameraAsset,
          params: params,
          cameraParams: cameraParams,
          cursorRecording: cursorRecording,
          cameraAssetIsPreStyled: cameraAssetIsPreStyled,
          cameraPlacementSourceRect: cameraPlacementSourceRect,
          screenSourceMode: screenSourceMode,
          screenAudioAsset: screenSourceMode == .precompositedCanvas ? asset : nil
        )
      else {
        cleanupTemporaryArtifacts()
        completion(
          .failure(
            NSError(
              domain: "Letterbox",
              code: -1,
              userInfo: [NSLocalizedDescriptionKey: "Failed to build composition"]
            )
          )
        )
        return
      }

      let preset = pickPreset(for: comp.asset)
      guard let export = AVAssetExportSession(asset: comp.asset, presetName: preset) else {
        cleanupTemporaryArtifacts()
        completion(
          .failure(
            NSError(
              domain: "Letterbox",
              code: -2,
              userInfo: [NSLocalizedDescriptionKey: "Cannot create export session (preset=\(preset))"]
            )
          )
        )
        return
      }

      export.videoComposition = comp.videoComposition
      export.audioMix = AudioMixEngine.makeAudioMix(
        asset: comp.asset,
        volumePercent: resolvedAudioMix.volumePercent,
        gainDb: resolvedAudioMix.gainDb
      )

      let requestedType = requestedFileType(for: format)
      if let requestedType, export.supportedFileTypes.contains(requestedType) {
        export.outputFileType = requestedType
      } else if let first = export.supportedFileTypes.first {
        export.outputFileType = first
      } else {
        cleanupTemporaryArtifacts()
        completion(
          .failure(
            NSError(
              domain: "Letterbox",
              code: -10,
              userInfo: [NSLocalizedDescriptionKey: "No supported output file types"]
            )
          )
        )
        return
      }

      let chosenType = export.outputFileType ?? .mov
      let finalURL = outputURL
        .deletingPathExtension()
        .appendingPathExtension(ext(for: chosenType))

      if FileManager.default.fileExists(atPath: finalURL.path) {
        try? FileManager.default.removeItem(at: finalURL)
      }

      export.outputURL = finalURL
      export.shouldOptimizeForNetworkUse = true

      NativeLogger.i(
        "Export",
        "Starting final export session",
        context: [
          "input": resolvedScreenInputURL.path,
          "cameraInput": resolvedCameraInputURL?.path ?? "nil",
          "cameraAssetIsPreStyled": cameraAssetIsPreStyled,
          "screenSourceMode": screenSourceMode.rawValue,
          "screenZoomBaked": comp.debugInfo.screenZoomIsPrecomposited,
          "output": outputURL.path,
          "target": "\(Int(target.width))x\(Int(target.height))",
          "renderSize":
            "\(Int(comp.videoComposition.renderSize.width))x\(Int(comp.videoComposition.renderSize.height))",
          "fpsHint": fpsHint,
          "format": format,
          "codec": codec,
          "bitrate": bitrate,
          "autoNormalizeOnExport": autoNormalizeOnExport,
          "targetLoudnessDbfs": targetLoudnessDbfs,
          "resolvedGainDb": resolvedAudioMix.gainDb,
          "resolvedVolumePercent": resolvedAudioMix.volumePercent,
          "sourcePeakDbfs": resolvedAudioMix.sourcePeakDbfs ?? NSNull(),
          "normalizationGainDb": resolvedAudioMix.normalizationGainDb ?? NSNull(),
          "backgroundColor": self.formattedBackgroundColor(backgroundColor),
          "backgroundImagePath": backgroundImagePath ?? "nil",
          "hasCustomBackground": backgroundColor != nil || backgroundImagePath != nil,
          "supportedTypes": export.supportedFileTypes.map(\.rawValue),
          "finalURL": finalURL.path,
        ]
      )

      runExportSession(
        export,
        outputURL: finalURL,
        progressRange: progressRange,
        onProgress: onProgress,
        logOutputInfo: true
      ) { [weak self] result in
        guard let self else {
          completion(result)
          return
        }

        switch result {
        case .success(let finalURL):
          if cameraAssetIsPreStyled,
            let resolvedCameraInputURL,
            let cameraParams,
            let validationError = self.validateFinalStyledCameraExport(
              styledCameraAsset: AVAsset(url: resolvedCameraInputURL),
              finalExportAsset: AVAsset(url: finalURL),
              canvasSize: target,
              cameraParams: cameraParams,
              placementSourceRect: cameraPlacementSourceRect
            )
          {
            NativeLogger.e(
              "Export",
              "Final styled camera export validation failed",
              context: validationError.userInfo
            )
            self.removeFileIfExists(finalURL)
            self.cleanupTemporaryArtifacts()
            completion(.failure(validationError))
            return
          }

          self.cleanupTemporaryArtifacts()
          completion(.success(finalURL))

        case .failure(let error):
          self.cleanupTemporaryArtifacts()
          completion(.failure(error))
        }
      }
    }

    func beginScreenPhase(
      resolvedCameraInputURL: URL?,
      cameraAssetIsPreStyled: Bool,
      cameraPlacementSourceRect: CGRect?,
      screenPrepassRange: ClosedRange<Double>?,
      finalRange: ClosedRange<Double>
    ) {
      guard shouldUseScreenPrepass, let cursorRecording else {
        beginFinalExport(
          resolvedScreenInputURL: inputURL,
          resolvedCameraInputURL: resolvedCameraInputURL,
          progressRange: finalRange,
          cameraAssetIsPreStyled: cameraAssetIsPreStyled,
          cameraPlacementSourceRect: cameraPlacementSourceRect,
          screenSourceMode: .liveScreenTrack
        )
        return
      }

      let prepassRange = screenPrepassRange ?? finalRange
      screenPrepassPipeline.prepareIntermediate(
        inputURL: inputURL,
        params: params,
        cursorRecording: cursorRecording,
        isCancelled: { [weak self] in self?.isCancelled ?? true },
        onProgress: { progress in
          onProgress?(scaledProgress(progress, into: prepassRange))
        }
      ) { [weak self] result in
        switch result {
        case .success(let prepared):
          prepared.temporaryArtifacts.forEach { self?.registerTemporaryArtifact($0) }
          if let validationError = self?.validateScreenPrepassIntermediate(
            rawScreenAsset: asset,
            prepassScreenAsset: AVAsset(url: prepared.url)
          ) {
            NativeLogger.e(
              "Export",
              "Screen pre-pass validation failed",
              context: validationError.userInfo
            )
            self?.cleanupTemporaryArtifacts()
            completion(.failure(validationError))
            return
          }
          beginFinalExport(
            resolvedScreenInputURL: prepared.url,
            resolvedCameraInputURL: resolvedCameraInputURL,
            progressRange: finalRange,
            cameraAssetIsPreStyled: cameraAssetIsPreStyled,
            cameraPlacementSourceRect: cameraPlacementSourceRect,
            screenSourceMode: .precompositedCanvas
          )

        case .failure(let error):
          self?.cleanupTemporaryArtifacts()
          completion(.failure(error))
        }
      }
    }

    if let cameraInputURL,
      let cameraParams,
      shouldUseCameraPrepass
    {
      let cameraAsset = AVAsset(url: cameraInputURL)
      let cameraRange: ClosedRange<Double> = shouldUseScreenPrepass ? (0.0...0.35) : (0.0...0.35)
      let screenRange: ClosedRange<Double>? = shouldUseScreenPrepass ? (0.35...0.65) : nil
      let finalRange: ClosedRange<Double> = shouldUseScreenPrepass ? (0.65...1.0) : (0.35...1.0)
      cameraPrepassPipeline.prepareIntermediate(
        inputURL: cameraInputURL,
        canvasSize: target,
        params: cameraParams,
        fpsHint: fpsHint,
        isCancelled: { [weak self] in self?.isCancelled ?? true },
        onProgress: { progress in
          onProgress?(scaledProgress(progress, into: cameraRange))
        }
      ) { [weak self] result in
        switch result {
        case .success(let prepared):
          prepared.temporaryArtifacts.forEach { self?.registerTemporaryArtifact($0) }

          if let validationError = self?.validateStyledCameraIntermediate(
            rawCameraAsset: cameraAsset,
            styledCameraAsset: AVAsset(url: prepared.url),
            placementSourceRect: prepared.placementSourceRect
          ) {
            NativeLogger.e(
              "Export",
              "Camera pre-pass validation failed",
              context: validationError.userInfo
            )
            self?.cleanupTemporaryArtifacts()
            completion(.failure(validationError))
            return
          }

          NativeLogger.i(
            "Export",
            "Camera pre-pass intermediate ready",
            context: [
              "path": prepared.url.path,
              "cameraAssetIsPreStyled": prepared.cameraAssetIsPreStyled,
              "placementSourceRect": NSStringFromRect(prepared.placementSourceRect ?? .zero),
            ]
          )

          beginScreenPhase(
            resolvedCameraInputURL: prepared.url,
            cameraAssetIsPreStyled: prepared.cameraAssetIsPreStyled,
            cameraPlacementSourceRect: prepared.placementSourceRect,
            screenPrepassRange: screenRange,
            finalRange: finalRange
          )

        case .failure(let error):
          self?.cleanupTemporaryArtifacts()
          completion(.failure(error))
        }
      }
      return
    }

    beginScreenPhase(
      resolvedCameraInputURL: cameraInputURL,
      cameraAssetIsPreStyled: false,
      cameraPlacementSourceRect: nil,
      screenPrepassRange: shouldUseScreenPrepass ? (0.0...0.30) : nil,
      finalRange: shouldUseScreenPrepass ? (0.30...1.0) : (0.0...1.0)
    )
  }

  private struct ResolvedAudioMixControls {
    let gainDb: Double
    let volumePercent: Double
    let sourcePeakDbfs: Double?
    let normalizationGainDb: Double?
  }

  private func resolveAudioMixControls(
    asset: AVAsset,
    userGainDb: Double,
    userVolumePercent: Double,
    autoNormalizeOnExport: Bool,
    targetLoudnessDbfs: Double
  ) -> ResolvedAudioMixControls {
    let clampedGainDb = max(0.0, min(24.0, userGainDb))
    let clampedVolumePercent = max(0.0, min(100.0, userVolumePercent))

    guard autoNormalizeOnExport else {
      return ResolvedAudioMixControls(
        gainDb: clampedGainDb,
        volumePercent: clampedVolumePercent,
        sourcePeakDbfs: nil,
        normalizationGainDb: nil
      )
    }

    guard let sourcePeakLinear = estimateAudioPeakLinear(asset: asset), sourcePeakLinear > 0.000001 else {
      NativeLogger.w(
        "Export",
        "Auto-normalize skipped: no measurable audio peak"
      )
      return ResolvedAudioMixControls(
        gainDb: clampedGainDb,
        volumePercent: clampedVolumePercent,
        sourcePeakDbfs: nil,
        normalizationGainDb: nil
      )
    }

    let clampedTargetDbfs = max(-24.0, min(-6.0, targetLoudnessDbfs))
    let targetLinear = pow(10.0, clampedTargetDbfs / 20.0)
    let userLinear = (clampedVolumePercent / 100.0) * pow(10.0, clampedGainDb / 20.0)
    let normalizeLinear = targetLinear / sourcePeakLinear
    let normalizationGainDb = 20.0 * log10(max(normalizeLinear, 0.000000001))

    // Apply user controls after normalization intent.
    var resolvedLinear = userLinear * normalizeLinear
    let maxLinear = pow(10.0, 24.0 / 20.0)  // aligns with current +24dB max
    resolvedLinear = max(0.0, min(maxLinear, resolvedLinear))

    let resolvedGainDb: Double
    let resolvedVolumePercent: Double
    if resolvedLinear <= 1.0 {
      resolvedGainDb = 0.0
      resolvedVolumePercent = resolvedLinear * 100.0
    } else {
      resolvedGainDb = min(24.0, 20.0 * log10(resolvedLinear))
      resolvedVolumePercent = 100.0
    }

    return ResolvedAudioMixControls(
      gainDb: resolvedGainDb,
      volumePercent: resolvedVolumePercent,
      sourcePeakDbfs: AudioLevelEstimator.dbfs(for: sourcePeakLinear),
      normalizationGainDb: normalizationGainDb
    )
  }

  private func estimateAudioPeakLinear(asset: AVAsset) -> Double? {
    guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
      return nil
    }

    do {
      let reader = try AVAssetReader(asset: asset)
      let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { return nil }
      reader.add(output)
      guard reader.startReading() else { return nil }

      var peak = 0.0
      while reader.status == .reading {
        guard let sample = output.copyNextSampleBuffer() else { break }
        if let estimate = AudioLevelEstimator.estimatePeak(sampleBuffer: sample) {
          peak = max(peak, estimate.linear)
        }
        CMSampleBufferInvalidate(sample)
      }

      if reader.status == .failed {
        NativeLogger.w(
          "Export",
          "Audio peak analysis failed",
          context: ["error": reader.error?.localizedDescription ?? "unknown"]
        )
      }

      return peak
    } catch {
      NativeLogger.w(
        "Export",
        "Audio peak analysis failed to start",
        context: ["error": error.localizedDescription]
      )
      return nil
    }
  }

  private func ext(for type: AVFileType) -> String {
    switch type {
    case .mp4: return "mp4"
    case .mov: return "mov"
    case .m4v: return "m4v"

    default:
      // Last-resort safe default
      return "mov"
    }
  }

  private func requestedFileType(for format: String) -> AVFileType? {
    switch format.lowercased() {
    case "mp4": return .mp4
    case "mov": return .mov
    case "m4v": return .m4v
    case "gif": return nil  // handled by a separate GIF export pipeline
    default: return .mov
    }
  }

  private func logExportedFileInfo(url: URL) {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
      NativeLogger.w("Export", "No video track", context: ["url": url.path])
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
      "Export", "Exported file info",
      context: [
        "url": url.path,
        "w": w, "h": h,
        "nominalFps": track.nominalFrameRate,
        "estimatedDataRate_bps": track.estimatedDataRate,
        "file_bytes": bytes,
        "duration_s": seconds,
        "bitrate_from_file_bps": bpsFromFile,
      ])
  }

#if DEBUG
  func _testShouldUseCameraPrepass(cameraParams: CameraCompositionParams?) -> Bool {
    cameraPrepassPipeline.requiresPrepass(cameraParams: cameraParams)
  }

  func _testShouldUseScreenPrepass(
    cameraAssetURL: URL?,
    cameraParams: CameraCompositionParams?,
    params: CompositionParams,
    cursorRecording: CursorRecording?
  ) -> Bool {
    screenPrepassPipeline.requiresPrepass(
      cameraAssetURL: cameraAssetURL,
      cameraParams: cameraParams,
      params: params,
      cursorRecording: cursorRecording
    )
  }

  func _testPrepareCameraIntermediate(
    inputURL: URL,
    canvasSize: CGSize,
    cameraParams: CameraCompositionParams,
    fpsHint: Int32,
    completion: @escaping (Result<CameraPreparedIntermediate, Error>) -> Void
  ) {
    cameraPrepassPipeline.prepareIntermediate(
      inputURL: inputURL,
      canvasSize: canvasSize,
      params: cameraParams,
      fpsHint: fpsHint,
      isCancelled: { false },
      onProgress: nil,
      completion: completion
    )
  }

  func _testPrepareScreenIntermediate(
    inputURL: URL,
    params: CompositionParams,
    cursorRecording: CursorRecording,
    completion: @escaping (Result<ScreenPreparedIntermediate, Error>) -> Void
  ) {
    screenPrepassPipeline.prepareIntermediate(
      inputURL: inputURL,
      params: params,
      cursorRecording: cursorRecording,
      isCancelled: { false },
      onProgress: nil,
      completion: completion
    )
  }

  func _testValidateStyledCameraIntermediate(
    rawCameraURL: URL,
    styledCameraURL: URL,
    placementSourceRect: CGRect? = nil
  ) -> NSError? {
    validateStyledCameraIntermediate(
      rawCameraAsset: AVAsset(url: rawCameraURL),
      styledCameraAsset: AVAsset(url: styledCameraURL),
      placementSourceRect: placementSourceRect
    )
  }

  func _testValidateFinalStyledCameraExport(
    styledCameraURL: URL,
    finalExportURL: URL,
    canvasSize: CGSize,
    cameraParams: CameraCompositionParams,
    placementSourceRect: CGRect? = nil
  ) -> NSError? {
    validateFinalStyledCameraExport(
      styledCameraAsset: AVAsset(url: styledCameraURL),
      finalExportAsset: AVAsset(url: finalExportURL),
      canvasSize: canvasSize,
      cameraParams: cameraParams,
      placementSourceRect: placementSourceRect
    )
  }

  func _testValidateScreenPrepassIntermediate(
    rawScreenURL: URL,
    prepassScreenURL: URL
  ) -> NSError? {
    validateScreenPrepassIntermediate(
      rawScreenAsset: AVAsset(url: rawScreenURL),
      prepassScreenAsset: AVAsset(url: prepassScreenURL)
    )
  }
#endif

}
