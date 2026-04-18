import AVFoundation
import AppKit
import QuartzCore

// Orchestrates export stages; camera-only pixel preprocessing stays in the pre-pass pipeline.
final class LetterboxExporter {
  private struct StaleTemporaryArtifactSweepResult {
    let filesRemoved: Int
    let bytesReclaimed: Int64
  }

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
    let averageLuma: Double
    let dominantRedRatio: Double
    let dominantGreenRatio: Double
    let dominantBlueRatio: Double

    func maxAverageChannelDelta(comparedTo other: FrameColorMetrics) -> Double {
      max(
        abs(averageRed - other.averageRed),
        max(
          abs(averageGreen - other.averageGreen),
          abs(averageBlue - other.averageBlue)
        )
      )
    }
  }

  private struct ValidationThresholds {
    let lumaFailure: Double
    let channelFailure: Double
  }

  private struct CropCandidate {
    let image: CGImage
    let pixelRect: CGRect
    let flipY: Bool
  }

  private struct AlignedCropPair {
    let reference: CropCandidate
    let final: CropCandidate
    let referenceContentMetrics: FrameContentMetrics
    let finalContentMetrics: FrameContentMetrics
    let referenceColorMetrics: FrameColorMetrics?
    let finalColorMetrics: FrameColorMetrics?
  }

  private let builder = CompositionBuilder()
  private let cameraPrepassPipeline = CameraStyledIntermediatePipeline()
  private let screenPrepassPipeline = ScreenZoomCursorIntermediatePipeline()
  private let staleTemporaryArtifactPrefixes = [
    "screen.screen-prepass.",
    "camera.styled.",
    "raw.styled.",
  ]
  private var currentSession: AVAssetExportSession?
  private var progressTimer: Timer?
  private var temporaryArtifacts: [URL] = []
  private var isCancelled = false
  private let validationSampleDimension = 64
  private let validationAlphaThreshold: UInt8 = 8
  private let validationNonBlackThreshold: UInt8 = 12
  private let validationLumaWarningThreshold = 0.04
  private let validationLumaFailureThreshold = 0.10
  private let validationChannelWarningThreshold = 0.05
  private let validationChannelFailureThreshold = 0.10
  private let screenPrepassValidationThresholds = ValidationThresholds(
    lumaFailure: 0.12,
    channelFailure: 0.14
  )
  private let animationToolValidationThresholds = ValidationThresholds(
    lumaFailure: 0.14,
    channelFailure: 0.18
  )

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

  private func fileSizeBytes(for url: URL, fileManager: FileManager = .default) -> Int64 {
    let rawValue =
      (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .int64Value
    return rawValue ?? 0
  }

  private func clearPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
  }

  private func writerStatusDescription(_ status: AVAssetWriter.Status) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .writing:
      return "writing"
    case .completed:
      return "completed"
    case .failed:
      return "failed"
    case .cancelled:
      return "cancelled"
    @unknown default:
      return "unrecognized"
    }
  }

  private func shouldSweepStaleTemporaryArtifact(named fileName: String) -> Bool {
    guard fileName.hasSuffix(".mov") else { return false }
    return staleTemporaryArtifactPrefixes.contains { fileName.hasPrefix($0) }
  }

  @discardableResult
  private func cleanupStaleExportIntermediates(
    at tempRoot: URL = AppPaths.tempRoot(),
    fileManager: FileManager = .default
  ) -> StaleTemporaryArtifactSweepResult {
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: tempRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return StaleTemporaryArtifactSweepResult(filesRemoved: 0, bytesReclaimed: 0)
    }

    var filesRemoved = 0
    var bytesReclaimed: Int64 = 0

    for url in urls where shouldSweepStaleTemporaryArtifact(named: url.lastPathComponent) {
      let fileBytes = fileSizeBytes(for: url, fileManager: fileManager)
      do {
        try fileManager.removeItem(at: url)
        filesRemoved += 1
        bytesReclaimed += fileBytes
      } catch {
        NativeLogger.w(
          "Export",
          "Failed to remove stale export temp artifact",
          context: [
            "path": url.path,
            "error": error.localizedDescription,
          ]
        )
      }
    }

    if filesRemoved > 0 {
      NativeLogger.i(
        "Export",
        "Cleaned stale export temp artifacts",
        context: [
          "tempPath": tempRoot.path,
          "filesRemoved": filesRemoved,
          "bytesReclaimed": bytesReclaimed,
        ]
      )
    }

    return StaleTemporaryArtifactSweepResult(
      filesRemoved: filesRemoved,
      bytesReclaimed: bytesReclaimed
    )
  }

  private func screenPrepassTempCapacityError(
    targetSize: CGSize,
    fpsHint: Int32,
    durationSeconds: Double,
    tempRoot: URL = AppPaths.tempRoot(),
    availableCapacityBytesOverride: Int64? = nil
  ) -> NSError? {
    let availableCapacityBytes =
      availableCapacityBytesOverride ?? StorageInfoProvider.availableCapacity(for: tempRoot)
    guard let availableCapacityBytes else { return nil }

    let estimatedRequiredTempBytes = ScreenZoomCursorIntermediatePipeline.estimatedTempRequirementBytes(
      renderSize: targetSize,
      fpsHint: fpsHint,
      durationSeconds: durationSeconds
    )

    guard availableCapacityBytes < estimatedRequiredTempBytes else { return nil }

    return makeScreenPrepassExportError(
      stage: .build,
      reason: "The screen pre-pass requires more temporary disk space than is currently available.",
      context: [
        "tempPath": tempRoot.path,
        "availableTempBytes": availableCapacityBytes,
        "estimatedRequiredTempBytes": estimatedRequiredTempBytes,
        "target": "\(Int(targetSize.width))x\(Int(targetSize.height))",
        "fpsHint": fpsHint,
        "durationSeconds": durationSeconds,
      ]
    )
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

  private func sampleFrameImage(
    asset: AVAsset,
    videoComposition: AVVideoComposition? = nil
  ) throws -> CGImage {
    try sampleFrameImage(
      asset: asset,
      videoComposition: videoComposition,
      at: validationSampleTime(for: asset)
    )
  }

  private func sampleFrameImage(
    asset: AVAsset,
    videoComposition: AVVideoComposition? = nil,
    at sampleTime: CMTime
  ) throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = videoComposition == nil
    generator.videoComposition = videoComposition
    generator.maximumSize = CGSize(
      width: validationSampleDimension,
      height: validationSampleDimension
    )
    return try generator.copyCGImage(at: sampleTime, actualTime: nil)
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
    let colorSpace = VideoColorPipeline.workingColorSpace

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
    let colorSpace = VideoColorPipeline.workingColorSpace

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
      averageLuma:
        ((redTotal * 0.2126) + (greenTotal * 0.7152) + (blueTotal * 0.0722))
        / Double(visiblePixels),
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
    cropCandidates(
      from: image,
      cropRect: cropRect,
      canvasSize: canvasSize
    ).map(\.image)
  }

  private func cropCandidates(
    from image: CGImage,
    cropRect: CGRect,
    canvasSize: CGSize
  ) -> [CropCandidate] {
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
      guard let cropped = image.cropping(to: pixelRect) else { return nil }
      return CropCandidate(image: cropped, pixelRect: pixelRect, flipY: flipY)
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

  private func bestColorMetrics(
    from image: CGImage,
    cropRect: CGRect?,
    canvasSize: CGSize,
    ignoreTransparentPixels: Bool
  ) -> FrameColorMetrics? {
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
      .compactMap { analyzeFrameColorMetrics($0, ignoreTransparentPixels: ignoreTransparentPixels) }
      .max(by: { lhs, rhs in
        lhs.visiblePixels < rhs.visiblePixels
      })
  }

  private func makeFinalExportValidationError(
    reason: String,
    context: [String: Any] = [:]
  ) -> NSError {
    var userInfo: [String: Any] = [
      NSLocalizedDescriptionKey: "Export output failed validation. \(reason)",
      "nativeErrorCode": NativeErrorCode.exportError,
      "stage": "final_output_validation",
      "reason": reason,
    ]
    if !context.isEmpty {
      userInfo["context"] = context
    }
    return NSError(domain: "Letterbox.FinalOutputValidation", code: 1, userInfo: userInfo)
  }

  private func validationThresholds(
    for referenceComposition: AVVideoComposition
  ) -> ValidationThresholds {
    if referenceComposition.animationTool != nil {
      return animationToolValidationThresholds
    }

    return ValidationThresholds(
      lumaFailure: validationLumaFailureThreshold,
      channelFailure: validationChannelFailureThreshold
    )
  }

  private func logColorDriftIfNeeded(
    category: String,
    message: String,
    reference: FrameColorMetrics,
    candidate: FrameColorMetrics,
    extraContext: [String: Any] = [:]
  ) {
    let lumaDelta = candidate.averageLuma - reference.averageLuma
    let redDelta = candidate.averageRed - reference.averageRed
    let greenDelta = candidate.averageGreen - reference.averageGreen
    let blueDelta = candidate.averageBlue - reference.averageBlue
    let maxChannelDelta = candidate.maxAverageChannelDelta(comparedTo: reference)

    var context = extraContext
    context["referenceAverageRed"] = reference.averageRed
    context["referenceAverageGreen"] = reference.averageGreen
    context["referenceAverageBlue"] = reference.averageBlue
    context["referenceAverageLuma"] = reference.averageLuma
    context["candidateAverageRed"] = candidate.averageRed
    context["candidateAverageGreen"] = candidate.averageGreen
    context["candidateAverageBlue"] = candidate.averageBlue
    context["candidateAverageLuma"] = candidate.averageLuma
    context["deltaRed"] = redDelta
    context["deltaGreen"] = greenDelta
    context["deltaBlue"] = blueDelta
    context["deltaLuma"] = lumaDelta
    context["maxChannelDelta"] = maxChannelDelta

    NativeLogger.d(category, message, context: context)

    if abs(lumaDelta) > validationLumaWarningThreshold
      || maxChannelDelta > validationChannelWarningThreshold
    {
      NativeLogger.w(
        category,
        "\(message) exceeded warning threshold",
        context: context
      )
    }
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

  private func bestAlignedCropPair(
    referenceImage: CGImage,
    finalImage: CGImage,
    cropRect: CGRect,
    canvasSize: CGSize
  ) -> AlignedCropPair? {
    let referenceCandidates = cropCandidates(
      from: referenceImage,
      cropRect: cropRect,
      canvasSize: canvasSize
    )
    let finalCandidates = cropCandidates(
      from: finalImage,
      cropRect: cropRect,
      canvasSize: canvasSize
    )

    var bestPair: AlignedCropPair?
    var bestNonBlackScore = -Double.infinity
    var bestColorScore = Double.infinity

    for referenceCandidate in referenceCandidates {
      guard
        let finalCandidate = finalCandidates.first(where: { $0.flipY == referenceCandidate.flipY }),
        let referenceContentMetrics = analyzeFrameContent(
          referenceCandidate.image,
          ignoreTransparentPixels: false
        ),
        let finalContentMetrics = analyzeFrameContent(
          finalCandidate.image,
          ignoreTransparentPixels: false
        )
      else {
        continue
      }

      let referenceColorMetrics = analyzeFrameColorMetrics(
        referenceCandidate.image,
        ignoreTransparentPixels: false
      )
      let finalColorMetrics = analyzeFrameColorMetrics(
        finalCandidate.image,
        ignoreTransparentPixels: false
      )

      let nonBlackScore =
        referenceContentMetrics.nonBlackVisibleRatio + finalContentMetrics.nonBlackVisibleRatio
      let colorScore: Double
      if let referenceColorMetrics, let finalColorMetrics {
        let lumaDelta = abs(finalColorMetrics.averageLuma - referenceColorMetrics.averageLuma)
        let maxChannelDelta = finalColorMetrics.maxAverageChannelDelta(comparedTo: referenceColorMetrics)
        colorScore = lumaDelta + maxChannelDelta
      } else {
        colorScore = Double.infinity
      }

      if nonBlackScore > bestNonBlackScore + 0.0001
        || (abs(nonBlackScore - bestNonBlackScore) <= 0.0001 && colorScore < bestColorScore)
      {
        bestNonBlackScore = nonBlackScore
        bestColorScore = colorScore
        bestPair = AlignedCropPair(
          reference: referenceCandidate,
          final: finalCandidate,
          referenceContentMetrics: referenceContentMetrics,
          finalContentMetrics: finalContentMetrics,
          referenceColorMetrics: referenceColorMetrics,
          finalColorMetrics: finalColorMetrics
        )
      }
    }

    return bestPair
  }

  private func validateFinalStyledCameraExport(
    referenceAsset: AVAsset,
    referenceComposition: AVVideoComposition,
    validationInfo: CompositionBuilder.ExportValidationInfo,
    finalExportAsset: AVAsset
  ) -> NSError? {
    let referenceSampleTime = validationSampleTime(for: referenceAsset)
    let finalSampleTime = validationSampleTime(for: finalExportAsset)
    let sampleTimeSeconds = min(referenceSampleTime.seconds, finalSampleTime.seconds)
    let sampleTime = CMTime(seconds: sampleTimeSeconds, preferredTimescale: 600)
    guard let resolvedSample = validationInfo.resolvedCameraSample(at: sampleTimeSeconds) else {
      NativeLogger.w(
        "Export",
        "Skipping final camera validation: no validation samples available",
        context: [
          "sampleTimeSeconds": sampleTimeSeconds,
          "compositionRenderSize": "\(Int(validationInfo.renderSize.width))x\(Int(validationInfo.renderSize.height))",
          "cameraSampleCount": validationInfo.cameraSamples.count,
        ]
      )
      return nil
    }
    guard resolvedSample.isTrustworthy, let resolvedFrame = resolvedSample.cameraFrame else {
      NativeLogger.w(
        "Export",
        "Skipping final camera validation: unresolved camera frame at sample time",
        context: [
          "sampleTimeSeconds": sampleTimeSeconds,
          "compositionRenderSize": "\(Int(validationInfo.renderSize.width))x\(Int(validationInfo.renderSize.height))",
          "cameraSampleCount": validationInfo.cameraSamples.count,
          "zoomActiveAtSample": resolvedSample.zoomActive,
          "usedInterpolation": resolvedSample.usedInterpolation,
          "resolvedCameraFrame": resolvedSample.cameraFrame.map(NSStringFromRect) ?? "nil",
        ]
      )
      return nil
    }

    do {
      let referenceImage = try sampleFrameImage(
        asset: referenceAsset,
        videoComposition: referenceComposition,
        at: sampleTime
      )
      let finalImage = try sampleFrameImage(asset: finalExportAsset, at: sampleTime)
      let finalEncodedSize = orientedSize(for: finalExportAsset)
        ?? CGSize(width: finalImage.width, height: finalImage.height)

      guard let cropPair = bestAlignedCropPair(
        referenceImage: referenceImage,
        finalImage: finalImage,
        cropRect: resolvedFrame,
        canvasSize: validationInfo.renderSize
      ) else {
        NativeLogger.w(
          "Export",
          "Skipping final camera validation: unable to derive aligned crop pair",
          context: [
            "sampleTimeSeconds": sampleTimeSeconds,
            "compositionRenderSize": "\(Int(validationInfo.renderSize.width))x\(Int(validationInfo.renderSize.height))",
            "finalEncodedSize": "\(Int(finalEncodedSize.width))x\(Int(finalEncodedSize.height))",
            "resolvedCameraFrame": NSStringFromRect(resolvedFrame),
            "zoomActiveAtSample": resolvedSample.zoomActive,
            "usedInterpolation": resolvedSample.usedInterpolation,
          ]
        )
        return nil
      }

      guard cropPair.referenceContentMetrics.nonBlackVisibleRatio >= 0.05 else {
        return nil
      }

      let requiredNonBlackRatio = max(0.01, cropPair.referenceContentMetrics.nonBlackVisibleRatio * 0.2)
      let validationContext: [String: Any] = [
        "sampleTimeSeconds": sampleTimeSeconds,
        "compositionRenderSize": "\(Int(validationInfo.renderSize.width))x\(Int(validationInfo.renderSize.height))",
        "finalEncodedSize": "\(Int(finalEncodedSize.width))x\(Int(finalEncodedSize.height))",
        "resolvedCameraFrame": NSStringFromRect(resolvedFrame),
        "referenceCropPixelRect": NSStringFromRect(cropPair.reference.pixelRect),
        "finalCropPixelRect": NSStringFromRect(cropPair.final.pixelRect),
        "selectedCropOrientation": cropPair.reference.flipY ? "flippedY" : "nativeY",
        "zoomActiveAtSample": resolvedSample.zoomActive,
        "usedInterpolation": resolvedSample.usedInterpolation,
      ]

      NativeLogger.d(
        "Export",
        "Final styled camera validation metrics",
        context: validationContext.merging(
          [
            "referenceCropNonBlackRatio": cropPair.referenceContentMetrics.nonBlackVisibleRatio,
            "finalCropNonBlackRatio": cropPair.finalContentMetrics.nonBlackVisibleRatio,
            "requiredNonBlackRatio": requiredNonBlackRatio,
          ],
          uniquingKeysWith: { _, new in new }
        )
      )

      guard cropPair.finalContentMetrics.nonBlackVisibleRatio >= requiredNonBlackRatio else {
        return makeAdvancedCameraExportError(
          stage: .finalOutputValidation,
          reason: "The final exported camera region rendered blank or black video.",
          context: validationContext.merging(
            [
              "referenceCropNonBlackRatio": cropPair.referenceContentMetrics.nonBlackVisibleRatio,
              "finalCropNonBlackRatio": cropPair.finalContentMetrics.nonBlackVisibleRatio,
              "requiredNonBlackRatio": requiredNonBlackRatio,
            ],
            uniquingKeysWith: { _, new in new }
          )
        )
      }

      if let referenceColorMetrics = cropPair.referenceColorMetrics,
        let finalCropColorMetrics = cropPair.finalColorMetrics
      {
        logColorDriftIfNeeded(
          category: "Export",
          message: "Final styled camera color validation metrics",
          reference: referenceColorMetrics,
          candidate: finalCropColorMetrics,
          extraContext: validationContext
        )

        let maxChannelDelta = finalCropColorMetrics.maxAverageChannelDelta(comparedTo: referenceColorMetrics)
        let lumaDelta = abs(finalCropColorMetrics.averageLuma - referenceColorMetrics.averageLuma)
        if lumaDelta > validationLumaFailureThreshold
          || maxChannelDelta > validationChannelFailureThreshold
        {
          return makeAdvancedCameraExportError(
            stage: .finalOutputValidation,
            reason: "The final exported camera region drifted materially in brightness or color.",
            context: validationContext.merging(
              [
                "referenceAverageLuma": referenceColorMetrics.averageLuma,
                "finalAverageLuma": finalCropColorMetrics.averageLuma,
                "lumaDelta": finalCropColorMetrics.averageLuma - referenceColorMetrics.averageLuma,
                "maxChannelDelta": maxChannelDelta,
              ],
              uniquingKeysWith: { _, new in new }
            )
          )
        }
      } else {
        NativeLogger.w(
          "Export",
          "Skipping final camera color validation: crop color metrics unavailable",
          context: validationContext
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

      logColorDriftIfNeeded(
        category: "Export",
        message: "Screen pre-pass color validation metrics",
        reference: rawColorMetrics,
        candidate: prepassColorMetrics
      )

      let lumaDelta = abs(prepassColorMetrics.averageLuma - rawColorMetrics.averageLuma)
      let maxChannelDelta = prepassColorMetrics.maxAverageChannelDelta(comparedTo: rawColorMetrics)
      if lumaDelta > screenPrepassValidationThresholds.lumaFailure
        || maxChannelDelta > screenPrepassValidationThresholds.channelFailure
      {
        return makeScreenPrepassExportError(
          stage: .validation,
          reason: "The screen pre-pass drifted materially in brightness or color.",
          context: [
            "rawAverageLuma": rawColorMetrics.averageLuma,
            "prepassAverageLuma": prepassColorMetrics.averageLuma,
            "lumaDelta": prepassColorMetrics.averageLuma - rawColorMetrics.averageLuma,
            "maxChannelDelta": maxChannelDelta,
            "lumaFailureThreshold": screenPrepassValidationThresholds.lumaFailure,
            "channelFailureThreshold": screenPrepassValidationThresholds.channelFailure,
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

  private func validateFinalExportReferenceRender(
    referenceAsset: AVAsset,
    referenceComposition: AVVideoComposition,
    finalExportAsset: AVAsset,
    inlineCameraRenderPlan: CompositionBuilder.InlineCameraRenderPlan? = nil,
    backgroundColor: Int? = nil,
    backgroundImagePath: String? = nil
  ) -> NSError? {
    do {
      let sampleTime = min(max(referenceAsset.duration.seconds * 0.5, 0.0), max(referenceAsset.duration.seconds - 0.001, 0.0))
      let referenceImage: CGImage
      if let inlineCameraRenderPlan {
        let screenImage = try sampleFrameImage(
          asset: referenceAsset,
          videoComposition: referenceComposition,
          at: CMTime(seconds: sampleTime, preferredTimescale: 600)
        )
        let cameraSourceImage = try sampleInlineCameraTrackImage(
          asset: referenceAsset,
          trackID: inlineCameraRenderPlan.cameraTrackID,
          time: sampleTime
        )
        let renderer = InlineCameraRenderer(
          renderSize: referenceComposition.renderSize,
          backgroundColor: backgroundColor,
          backgroundImagePath: backgroundImagePath
        )
        let composedImage = renderer.makeCompositedImage(
          screenImage: CIImage(cgImage: screenImage),
          cameraSourceImage: cameraSourceImage,
          presentationTime: sampleTime,
          plan: inlineCameraRenderPlan
        )
        let ciContext = VideoColorPipeline.makeCIContext()
        guard
          let composedCGImage = ciContext.createCGImage(
            composedImage,
            from: CGRect(origin: .zero, size: referenceComposition.renderSize),
            format: .RGBA8,
            colorSpace: VideoColorPipeline.workingColorSpace
          )
        else {
          return makeFinalExportValidationError(
            reason: "The inline-camera validation render could not be materialized."
          )
        }
        referenceImage = composedCGImage
      } else {
        referenceImage = try sampleFrameImage(
          asset: referenceAsset,
          videoComposition: referenceComposition,
          at: CMTime(seconds: sampleTime, preferredTimescale: 600)
        )
      }
      let finalImage = try sampleFrameImage(
        asset: finalExportAsset,
        at: CMTime(seconds: sampleTime, preferredTimescale: 600)
      )

      guard
        let referenceMetrics = analyzeFrameColorMetrics(referenceImage, ignoreTransparentPixels: false),
        let finalMetrics = analyzeFrameColorMetrics(finalImage, ignoreTransparentPixels: false)
      else {
        return makeFinalExportValidationError(
          reason: "The final export color validator could not analyze the rendered frames."
        )
      }

      logColorDriftIfNeeded(
        category: "Export",
        message: "Final export reference-render color validation metrics",
        reference: referenceMetrics,
        candidate: finalMetrics,
        extraContext: [
          "referenceRenderSize":
            "\(Int(referenceComposition.renderSize.width))x\(Int(referenceComposition.renderSize.height))",
        ]
      )

      let thresholds = validationThresholds(for: referenceComposition)
      let lumaDelta = abs(finalMetrics.averageLuma - referenceMetrics.averageLuma)
      let maxChannelDelta = finalMetrics.maxAverageChannelDelta(comparedTo: referenceMetrics)
      if lumaDelta > thresholds.lumaFailure
        || maxChannelDelta > thresholds.channelFailure
      {
        return makeFinalExportValidationError(
          reason: "The final exported file drifted materially from the reference composition render.",
          context: [
            "referenceAverageLuma": referenceMetrics.averageLuma,
            "finalAverageLuma": finalMetrics.averageLuma,
            "lumaDelta": finalMetrics.averageLuma - referenceMetrics.averageLuma,
            "maxChannelDelta": maxChannelDelta,
            "lumaFailureThreshold": thresholds.lumaFailure,
            "channelFailureThreshold": thresholds.channelFailure,
          ]
        )
      }

      return nil
    } catch {
      return makeFinalExportValidationError(
        reason: "The final export color validator could not sample the rendered frames.",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func sampleInlineCameraTrackImage(
    asset: AVAsset,
    trackID: CMPersistentTrackID,
    time: Double
  ) throws -> CIImage? {
    guard let track = asset.tracks(withMediaType: .video).first(where: { $0.trackID == trackID }) else {
      return nil
    }

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      return nil
    }
    reader.add(output)

    let searchWindow = max(referenceFrameDurationSeconds(for: asset), 0.15)
    let rangeStart = max(0.0, time - (searchWindow * 0.5))
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: rangeStart, preferredTimescale: 600),
      duration: CMTime(seconds: searchWindow, preferredTimescale: 600)
    )

    guard reader.startReading() else {
      throw reader.error ?? NSError(
        domain: "Letterbox",
        code: -26,
        userInfo: [NSLocalizedDescriptionKey: "Inline camera validation reader could not start"]
      )
    }

    let ciContext = VideoColorPipeline.makeCIContext()
    let normalizedTransform: CGAffineTransform = {
      let orientedRect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
      return track.preferredTransform.concatenating(
        CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)
      )
    }()
    let orientedSize: CGSize = {
      let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
      return CGSize(width: max(1.0, abs(rect.width)), height: max(1.0, abs(rect.height)))
    }()

    var bestImage: CIImage?
    var bestDelta = Double.greatestFiniteMagnitude
    while let sampleBuffer = output.copyNextSampleBuffer() {
      defer { CMSampleBufferInvalidate(sampleBuffer) }
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

      let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
      let delta = abs(sampleTime - time)
      if delta > bestDelta && sampleTime > time {
        break
      }

      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
      let orientedImage = VideoColorPipeline.sourceImage(
        pixelBuffer: pixelBuffer,
        formatDescription: formatDescription
      )
        .transformed(by: normalizedTransform)
        .cropped(to: CGRect(origin: .zero, size: orientedSize))
      guard
        let cgImage = ciContext.createCGImage(
          orientedImage,
          from: orientedImage.extent,
          format: .RGBA8,
          colorSpace: VideoColorPipeline.workingColorSpace
        )
      else {
        continue
      }

      bestImage = CIImage(cgImage: cgImage)
      bestDelta = delta
    }

    reader.cancelReading()
    return bestImage
  }

  private func referenceFrameDurationSeconds(for asset: AVAsset) -> Double {
    guard let track = asset.tracks(withMediaType: .video).first else {
      return 1.0 / 30.0
    }
    let fps = track.nominalFrameRate
    guard fps > 0 else { return 1.0 / 30.0 }
    return 1.0 / Double(fps)
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
    let stageStart = CFAbsoluteTimeGetCurrent()

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
          logExportStagePerformance(
            stage: "final_export",
            startedAt: stageStart,
            renderPath: "asset_export_session"
          )
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

  private func manualVideoCodec(for codec: String) -> AVVideoCodecType {
    if codec == "hevc", #available(macOS 10.13, *) {
      return .hevc
    }
    return .h264
  }

  private func manualAudioOutputSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
  }

  private func manualAudioWriterSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 2,
      AVSampleRateKey: 44_100,
      AVEncoderBitRateKey: 192_000,
    ]
  }

  private func runRenderedExportSession(
    asset: AVAsset,
    videoComposition: AVVideoComposition,
    audioMix: AVAudioMix?,
    outputURL: URL,
    outputFileType: AVFileType,
    codec: String,
    progressRange: ClosedRange<Double>,
    onProgress: ((Double) -> Void)?,
    inlineCameraRenderPlan: CompositionBuilder.InlineCameraRenderPlan? = nil,
    backgroundColor: Int? = nil,
    backgroundImagePath: String? = nil,
    logOutputInfo: Bool = false,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let videoTracks = asset.tracks(withMediaType: .video)
    guard !videoTracks.isEmpty else {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -11,
            userInfo: [NSLocalizedDescriptionKey: "Export source has no video track"]
          )
        )
      )
      return
    }

    let inlineCameraTrack = inlineCameraRenderPlan.flatMap { plan in
      videoTracks.first(where: { $0.trackID == plan.cameraTrackID })
    }
    if inlineCameraRenderPlan != nil && inlineCameraTrack == nil {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -29,
            userInfo: [NSLocalizedDescriptionKey: "Manual export inline camera track could not be found in the composition"]
          )
        )
      )
      return
    }
    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
      reader = try AVAssetReader(asset: asset)
      writer = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
    } catch {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -12,
            userInfo: [
              NSLocalizedDescriptionKey: "Manual export renderer could not be initialized",
              NSUnderlyingErrorKey: error,
            ]
          )
        )
      )
      return
    }

    let videoOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: videoTracks,
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    videoOutput.videoComposition = videoComposition
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -13,
            userInfo: [NSLocalizedDescriptionKey: "Manual export renderer could not configure the video reader output"]
          )
        )
      )
      return
    }
    reader.add(videoOutput)

    var cameraOutput: AVAssetReaderTrackOutput?
    if let inlineCameraTrack {
      let candidateOutput = AVAssetReaderTrackOutput(
        track: inlineCameraTrack,
        outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
      )
      candidateOutput.alwaysCopiesSampleData = false
      guard reader.canAdd(candidateOutput) else {
        completion(
          .failure(
            NSError(
              domain: "Letterbox",
              code: -30,
              userInfo: [NSLocalizedDescriptionKey: "Manual export renderer could not configure the inline camera reader output"]
            )
          )
        )
        return
      }
      reader.add(candidateOutput)
      cameraOutput = candidateOutput
    }

    let renderSize = videoComposition.renderSize
    let videoInput: AVAssetWriterInput
    do {
      videoInput = try VideoColorPipeline.makeVideoWriterInput(
        baseOutputSettings: [
          AVVideoCodecKey: manualVideoCodec(for: codec),
          AVVideoWidthKey: Int(renderSize.width),
          AVVideoHeightKey: Int(renderSize.height),
        ],
        category: "Export",
        operation: "final_output_manual_render",
        extraContext: [
          "renderSize": "\(Int(renderSize.width))x\(Int(renderSize.height))",
          "outputFileType": outputFileType.rawValue,
        ]
      )
    } catch let error as VideoColorPipeline.VideoWriterInputBuildError {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -14,
            userInfo: [
              NSLocalizedDescriptionKey: error.reason,
              "context": error.context,
            ]
          )
        )
      )
      return
    } catch {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -15,
            userInfo: [
              NSLocalizedDescriptionKey: "Manual export renderer could not create the video writer input",
              NSUnderlyingErrorKey: error,
            ]
          )
        )
      )
      return
    }
    videoInput.expectsMediaDataInRealTime = false
    let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(renderSize.width),
        kCVPixelBufferHeightKey as String: Int(renderSize.height),
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ]
    )
    guard writer.canAdd(videoInput) else {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -16,
            userInfo: [NSLocalizedDescriptionKey: "Manual export renderer could not add the video writer input"]
          )
        )
      )
      return
    }
    writer.add(videoInput)

    var audioOutput: AVAssetReaderAudioMixOutput?
    var audioInput: AVAssetWriterInput?
    if let audioTrack = asset.tracks(withMediaType: .audio).first {
      let candidateOutput = AVAssetReaderAudioMixOutput(
        audioTracks: [audioTrack],
        audioSettings: manualAudioOutputSettings()
      )
      candidateOutput.audioMix = audioMix
      candidateOutput.alwaysCopiesSampleData = false

      let candidateInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: manualAudioWriterSettings()
      )
      candidateInput.expectsMediaDataInRealTime = false

      if reader.canAdd(candidateOutput), writer.canAdd(candidateInput) {
        reader.add(candidateOutput)
        writer.add(candidateInput)
        audioOutput = candidateOutput
        audioInput = candidateInput
      } else {
        completion(
          .failure(
            NSError(
              domain: "Letterbox",
              code: -17,
              userInfo: [NSLocalizedDescriptionKey: "Manual export renderer could not configure the audio pipeline"]
            )
          )
        )
        return
      }
    }

    writer.shouldOptimizeForNetworkUse = true

    guard writer.startWriting() else {
      completion(
        .failure(
          writer.error
            ?? NSError(
              domain: "Letterbox",
              code: -18,
              userInfo: [NSLocalizedDescriptionKey: "Manual export writer could not start"]
            )
        )
      )
      return
    }

    guard reader.startReading() else {
      writer.cancelWriting()
      completion(
        .failure(
          reader.error
            ?? NSError(
              domain: "Letterbox",
              code: -19,
              userInfo: [NSLocalizedDescriptionKey: "Manual export reader could not start"]
            )
        )
      )
      return
    }

    let durationSeconds = max(asset.duration.seconds, 0.001)
    let lower = progressRange.lowerBound
    let span = progressRange.upperBound - progressRange.lowerBound
    let stageStart = CFAbsoluteTimeGetCurrent()
    let stateQueue = DispatchQueue(label: "Clingfy.FinalExportManualRender.State")
    let videoQueue = DispatchQueue(label: "Clingfy.FinalExportManualRender.Video")
    let audioQueue = DispatchQueue(label: "Clingfy.FinalExportManualRender.Audio")
    let frameDurationSeconds = max(videoComposition.frameDuration.seconds, 1.0 / 30.0)
    let renderBounds = CGRect(origin: .zero, size: renderSize)
    var videoFinished = false
    var audioFinished = audioInput == nil
    var completed = false
    var videoFrameIndex = 0
    var didLogScreenSourceColorMetadata = false
    var didLogCameraSourceColorMetadata = false
    let directRenderContext = VideoColorPipeline.makeCIContext()
    let inlineCameraRenderer = inlineCameraRenderPlan.map { _ in
      InlineCameraRenderer(
        renderSize: renderSize,
        backgroundColor: backgroundColor,
        backgroundImagePath: backgroundImagePath
      )
    }
    var currentCameraSampleBuffer: CMSampleBuffer?
    var nextCameraSampleBuffer: CMSampleBuffer?

    func invalidateCameraSamples() {
      if let currentCameraSampleBuffer {
        CMSampleBufferInvalidate(currentCameraSampleBuffer)
      }
      if let nextCameraSampleBuffer {
        CMSampleBufferInvalidate(nextCameraSampleBuffer)
      }
      currentCameraSampleBuffer = nil
      nextCameraSampleBuffer = nil
    }

    func manualRenderError(
      code: Int,
      reason: String,
      frameIndex: Int,
      context: [String: Any] = [:]
    ) -> NSError {
      var mergedContext: [String: Any] = [
        "stage": "final_manual_video_render",
        "frame": frameIndex,
        "writerStatus": self.writerStatusDescription(writer.status),
        "writerError": writer.error?.localizedDescription ?? "nil",
        "outputPath": outputURL.path,
        "outputFileBytes": self.fileSizeBytes(for: outputURL),
      ]
      context.forEach { mergedContext[$0.key] = $0.value }
      return NSError(
        domain: "Letterbox",
        code: code,
        userInfo: [
          NSLocalizedDescriptionKey: reason,
          "context": mergedContext,
        ]
      )
    }

    func fail(_ error: Error) {
      let shouldFinish: Bool = stateQueue.sync {
        guard !completed else { return false }
        completed = true
        return true
      }
      guard shouldFinish else { return }

      reader.cancelReading()
      videoInput.markAsFinished()
      audioInput?.markAsFinished()
      writer.cancelWriting()
      invalidateCameraSamples()
      removeFileIfExists(outputURL)

      DispatchQueue.main.async {
        completion(.failure(error))
      }
    }

    func finishIfReady() {
      stateQueue.async { [weak self] in
        guard videoFinished, audioFinished, !completed else { return }
        completed = true

        writer.finishWriting {
          reader.cancelReading()
          invalidateCameraSamples()
          DispatchQueue.main.async {
            if writer.status == .completed {
              onProgress?(progressRange.upperBound)
              logExportStagePerformance(
                stage: "final_export",
                frames: videoFrameIndex,
                startedAt: stageStart,
                renderPath: "manual_reader_writer"
              )
              if logOutputInfo {
                self?.logExportedFileInfo(url: outputURL)
              }
              completion(.success(outputURL))
            } else {
              self?.removeFileIfExists(outputURL)
              completion(
                .failure(
                  writer.error
                    ?? NSError(
                      domain: "Letterbox",
                      code: -20,
                      userInfo: [NSLocalizedDescriptionKey: "Manual export writer failed to finish"]
                    )
                )
              )
            }
          }
        }
      }
    }

    if let cameraOutput {
      nextCameraSampleBuffer = cameraOutput.copyNextSampleBuffer()
    }

    writer.startSession(atSourceTime: .zero)

    videoInput.requestMediaDataWhenReady(on: videoQueue) {
      while videoInput.isReadyForMoreMediaData {
        if self.isCancelled {
          fail(
            NSError(
              domain: "Letterbox",
              code: -999,
              userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]
            )
          )
          return
        }

        let shouldContinue = autoreleasepool { () -> Bool in
          guard let pixelBufferPool = videoAdaptor.pixelBufferPool else {
            fail(
              manualRenderError(
                code: -31,
                reason: "Manual export renderer has no pixel buffer pool.",
                frameIndex: videoFrameIndex
              )
            )
            return false
          }

          let allocation = makePooledPixelBuffer(from: pixelBufferPool)
          if allocation.status == kCVReturnWouldExceedAllocationThreshold {
            logExportBackpressure(stage: "final_export", frameIndex: videoFrameIndex)
            return false
          }

          guard allocation.status == kCVReturnSuccess, let renderedPixelBuffer = allocation.pixelBuffer else {
            fail(
              manualRenderError(
                code: -32,
                reason: "Manual export renderer could not allocate an output frame.",
                frameIndex: videoFrameIndex,
                context: ["status": allocation.status]
              )
            )
            return false
          }

          guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
            if reader.status == .failed {
              fail(
                reader.error
                  ?? NSError(
                    domain: "Letterbox",
                    code: -21,
                    userInfo: [NSLocalizedDescriptionKey: "Manual export video reader failed"]
                  )
              )
              return false
            }

            videoInput.markAsFinished()
            stateQueue.async {
              videoFinished = true
            }
            finishIfReady()
            return false
          }

          defer {
            CMSampleBufferInvalidate(sampleBuffer)
          }

          let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          let sampleTime = presentationTime.seconds
          DispatchQueue.main.async {
            onProgress?(lower + (min(max(sampleTime / durationSeconds, 0.0), 1.0) * span))
          }

          guard let screenPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            fail(
              manualRenderError(
                code: -33,
                reason: "Manual export video reader produced a frame without an image buffer.",
                frameIndex: videoFrameIndex
              )
            )
            return false
          }
          let screenFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)

          if !didLogScreenSourceColorMetadata {
            didLogScreenSourceColorMetadata = true
            VideoColorPipeline.logColorMetadata(
              category: "Export",
              message: "Final export screen source color metadata",
              formatDescription: screenFormatDescription,
              pixelBuffer: screenPixelBuffer,
              extraContext: [
                "output": outputURL.path,
                "renderPath": "manual_reader_writer",
              ]
            )
          }

          VideoColorPipeline.tag(pixelBuffer: renderedPixelBuffer)
          if let inlineCameraRenderPlan, let inlineCameraRenderer {
            while let queuedCameraSample = nextCameraSampleBuffer {
              let queuedTime = CMSampleBufferGetPresentationTimeStamp(queuedCameraSample).seconds
              if queuedTime <= sampleTime + (frameDurationSeconds * 0.5) {
                if let currentCameraSampleBuffer {
                  CMSampleBufferInvalidate(currentCameraSampleBuffer)
                }
                currentCameraSampleBuffer = queuedCameraSample
                nextCameraSampleBuffer = cameraOutput?.copyNextSampleBuffer()
              } else {
                break
              }
            }

            let cameraPixelBuffer: CVPixelBuffer? = {
              guard
                let resolvedSample = inlineCameraRenderPlan.resolvedSample(at: sampleTime),
                resolvedSample.frame != nil,
                resolvedSample.opacity > 0.001,
                let currentCameraSampleBuffer
              else {
                return nil
              }
              return CMSampleBufferGetImageBuffer(currentCameraSampleBuffer)
            }()
            let cameraFormatDescription = currentCameraSampleBuffer.flatMap {
              CMSampleBufferGetFormatDescription($0)
            }

            if let cameraPixelBuffer, !didLogCameraSourceColorMetadata {
              didLogCameraSourceColorMetadata = true
              VideoColorPipeline.logColorMetadata(
                category: "Export",
                message: "Final export camera source color metadata",
                formatDescription: cameraFormatDescription,
                pixelBuffer: cameraPixelBuffer,
                extraContext: [
                  "output": outputURL.path,
                  "renderPath": "manual_reader_writer",
                ]
              )
            }

            inlineCameraRenderer.render(
              screenPixelBuffer: screenPixelBuffer,
              screenFormatDescription: screenFormatDescription,
              cameraPixelBuffer: cameraPixelBuffer,
              cameraFormatDescription: cameraFormatDescription,
              cameraTrack: inlineCameraTrack!,
              presentationTime: sampleTime,
              plan: inlineCameraRenderPlan,
              to: renderedPixelBuffer
            )
          } else {
            let sourceImage = VideoColorPipeline.sourceImage(
              pixelBuffer: screenPixelBuffer,
              formatDescription: screenFormatDescription
            )
            let sourceBounds = CGRect(
              origin: .zero,
              size: CGSize(
                width: CVPixelBufferGetWidth(screenPixelBuffer),
                height: CVPixelBufferGetHeight(screenPixelBuffer)
              )
            )
            let imageToRender: CIImage
            if sourceBounds.size == renderBounds.size {
              imageToRender = sourceImage
            } else {
              imageToRender = sourceImage.transformed(
                by: CGAffineTransform(
                  scaleX: renderBounds.width / max(sourceBounds.width, 1.0),
                  y: renderBounds.height / max(sourceBounds.height, 1.0)
                )
              )
            }

            self.clearPixelBuffer(renderedPixelBuffer)
            directRenderContext.render(
              imageToRender,
              to: renderedPixelBuffer,
              bounds: renderBounds,
              colorSpace: VideoColorPipeline.workingColorSpace
            )
          }

          guard videoAdaptor.append(renderedPixelBuffer, withPresentationTime: presentationTime) else {
            fail(
              manualRenderError(
                code: inlineCameraRenderPlan == nil ? -22 : -34,
                reason: inlineCameraRenderPlan == nil
                  ? "Manual export video writer rejected a frame."
                  : "Manual export inline camera writer rejected a frame.",
                frameIndex: videoFrameIndex
              )
            )
            return false
          }

          logExportMemoryCheckpoint(
            stage: "final_manual_video_render",
            frameIndex: videoFrameIndex
          )
          videoFrameIndex += 1
          return true
        }

        if !shouldContinue {
          return
        }
      }
    }

    if let audioOutput, let audioInput {
      audioInput.requestMediaDataWhenReady(on: audioQueue) {
        while audioInput.isReadyForMoreMediaData {
          if self.isCancelled {
            fail(
              NSError(
                domain: "Letterbox",
                code: -999,
                userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]
              )
            )
            return
          }

          guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
            if reader.status == .failed {
              fail(
                reader.error
                  ?? NSError(
                    domain: "Letterbox",
                    code: -23,
                    userInfo: [NSLocalizedDescriptionKey: "Manual export audio reader failed"]
                  )
              )
              return
            }

            audioInput.markAsFinished()
            stateQueue.async {
              audioFinished = true
            }
            finishIfReady()
            return
          }

          if !audioInput.append(sampleBuffer) {
            fail(
              writer.error
                ?? NSError(
                  domain: "Letterbox",
                  code: -24,
                  userInfo: [NSLocalizedDescriptionKey: "Manual export audio writer rejected a sample"]
                )
            )
            return
          }
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
    cleanupTemporaryArtifacts()
    cleanupStaleExportIntermediates()

    let mediaSources = project.mediaSources()
    let inputURL = mediaSources.screenVideoURL
    let cameraInputURL = mediaSources.cameraVideoURL

    let asset = AVAsset(url: inputURL)
    let recordingMetadata = mediaSources.metadataURL.flatMap {
      try? RecordingMetadata.read(from: $0)
    }
    let cameraMetadata = mediaSources.cameraMetadataURL.flatMap { url -> CameraRecordingMetadata? in
      guard let data = try? Data(contentsOf: url) else { return nil }
      return try? JSONDecoder().decode(CameraRecordingMetadata.self, from: data)
    }
    let cameraSyncTimeline = CameraSyncTimelineResolver.resolve(
      recordingMetadata: recordingMetadata,
      cameraMetadata: cameraMetadata,
      screenAsset: asset,
      cameraAsset: cameraInputURL.map(AVAsset.init(url:)),
      logContext: [
        "context": "export",
        "projectPath": project.rootURL.path,
      ]
    )

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
    if shouldUseScreenPrepass,
      let tempCapacityError = screenPrepassTempCapacityError(
        targetSize: target,
        fpsHint: fpsHint,
        durationSeconds: asset.duration.seconds
      )
    {
      completion(.failure(tempCapacityError))
      return
    }

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
          cameraSyncTimeline: cameraSyncTimeline,
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
      let exportAudioMix = AudioMixEngine.makeAudioMix(
        asset: comp.asset,
        volumePercent: resolvedAudioMix.volumePercent,
        gainDb: resolvedAudioMix.gainDb
      )

      let requestedType = requestedFileType(for: format)
      let compatibleTypes = compatibleOutputTypes(
        for: comp.asset,
        preset: preset,
        requestedType: requestedType
      )
      guard let chosenType = compatibleTypes.requested ?? compatibleTypes.firstAvailable else {
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
      let finalURL = outputURL
        .deletingPathExtension()
        .appendingPathExtension(ext(for: chosenType))

      if FileManager.default.fileExists(atPath: finalURL.path) {
        try? FileManager.default.removeItem(at: finalURL)
      }

      var exportColorContext = VideoColorPipeline.metadataContext(
        prefix: "composition",
        metadata: VideoColorPipeline.compositionColorMetadata(comp.videoComposition)
      )
      VideoColorPipeline.metadataContext(
        prefix: "screenTrack",
        metadata: VideoColorPipeline.assetTrackColorMetadata(screenAsset.tracks(withMediaType: .video).first)
      ).forEach { exportColorContext[$0.key] = $0.value }
      VideoColorPipeline.metadataContext(
        prefix: "cameraTrack",
        metadata: VideoColorPipeline.assetTrackColorMetadata(cameraAsset?.tracks(withMediaType: .video).first)
      ).forEach { exportColorContext[$0.key] = $0.value }
      exportColorContext["workingColorSpace"] = VideoColorPipeline.workingColorSpaceName

      let renderSizeString =
        "\(Int(comp.videoComposition.renderSize.width))x\(Int(comp.videoComposition.renderSize.height))"
      let targetSizeString = "\(Int(target.width))x\(Int(target.height))"
      let sourcePeakDbfs: Any = resolvedAudioMix.sourcePeakDbfs ?? NSNull()
      let normalizationGainDb: Any = resolvedAudioMix.normalizationGainDb ?? NSNull()
      var exportStartContext: [String: Any] = [
        "input": resolvedScreenInputURL.path,
        "cameraInput": resolvedCameraInputURL?.path ?? "nil",
        "cameraAssetIsPreStyled": cameraAssetIsPreStyled,
        "screenSourceMode": screenSourceMode.rawValue,
        "screenZoomBaked": comp.debugInfo.screenZoomIsPrecomposited,
        "output": outputURL.path,
        "target": targetSizeString,
        "renderSize": renderSizeString,
        "fpsHint": fpsHint,
        "format": format,
        "codec": codec,
        "bitrate": bitrate,
        "autoNormalizeOnExport": autoNormalizeOnExport,
        "targetLoudnessDbfs": targetLoudnessDbfs,
        "resolvedGainDb": resolvedAudioMix.gainDb,
        "resolvedVolumePercent": resolvedAudioMix.volumePercent,
        "sourcePeakDbfs": sourcePeakDbfs,
        "normalizationGainDb": normalizationGainDb,
        "backgroundColor": self.formattedBackgroundColor(backgroundColor),
        "backgroundImagePath": backgroundImagePath ?? "nil",
        "hasCustomBackground": backgroundColor != nil || backgroundImagePath != nil,
        "supportedTypes": compatibleTypes.all.map(\.rawValue),
        "finalURL": finalURL.path,
      ]
      exportColorContext.forEach { exportStartContext[$0.key] = $0.value }
      let shouldUseManualRenderExport =
        cameraAssetIsPreStyled
        || comp.inlineCameraRenderPlan != nil
        || comp.videoComposition.animationTool != nil
      exportStartContext["finalRenderPath"] = shouldUseManualRenderExport ? "manual_reader_writer" : "asset_export_session"
      NativeLogger.i(
        "Export",
        "Starting final export session",
        context: exportStartContext
      )

      let runFinalExport: (@escaping (Result<URL, Error>) -> Void) -> Void = { [weak self] completion in
        guard let self else {
          completion(
            .failure(
              NSError(
                domain: "Letterbox",
                code: -25,
                userInfo: [NSLocalizedDescriptionKey: "Exporter deallocated before final export could start"]
              )
            )
          )
          return
        }

        if shouldUseManualRenderExport {
          self.runRenderedExportSession(
            asset: comp.asset,
            videoComposition: comp.videoComposition,
            audioMix: exportAudioMix,
            outputURL: finalURL,
            outputFileType: chosenType,
            codec: codec,
            progressRange: progressRange,
            onProgress: onProgress,
            inlineCameraRenderPlan: comp.inlineCameraRenderPlan,
            backgroundColor: backgroundColor,
            backgroundImagePath: backgroundImagePath,
            logOutputInfo: true,
            completion: completion
          )
          return
        }

        guard let export = AVAssetExportSession(asset: comp.asset, presetName: preset) else {
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
        export.audioMix = exportAudioMix
        export.outputFileType = chosenType
        export.outputURL = finalURL
        export.shouldOptimizeForNetworkUse = true

        self.runExportSession(
          export,
          outputURL: finalURL,
          progressRange: progressRange,
          onProgress: onProgress,
          logOutputInfo: true,
          completion: completion
        )
      }

      runFinalExport { [weak self] result in
        guard let self else {
          completion(result)
          return
        }

        switch result {
        case .success(let finalURL):
          if let validationError = self.validateFinalExportReferenceRender(
            referenceAsset: comp.asset,
            referenceComposition: comp.videoComposition,
            finalExportAsset: AVAsset(url: finalURL),
            inlineCameraRenderPlan: comp.inlineCameraRenderPlan,
            backgroundColor: backgroundColor,
            backgroundImagePath: backgroundImagePath
          ) {
            NativeLogger.e(
              "Export",
              "Final export reference-render validation failed",
              context: validationError.userInfo
            )
            self.removeFileIfExists(finalURL)
            self.cleanupTemporaryArtifacts()
            completion(.failure(validationError))
            return
          }

          if cameraAssetIsPreStyled,
            let validationInfo = comp.validationInfo,
            let validationError = self.validateFinalStyledCameraExport(
              referenceAsset: comp.asset,
              referenceComposition: comp.videoComposition,
              validationInfo: validationInfo,
              finalExportAsset: AVAsset(url: finalURL),
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
      guard shouldUseScreenPrepass else {
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

      let prepassCursorRecording = cursorRecording ?? CursorRecording(sprites: [], frames: [])
      let prepassRange = screenPrepassRange ?? finalRange
      screenPrepassPipeline.prepareIntermediate(
        inputURL: inputURL,
        params: params,
        cursorRecording: prepassCursorRecording,
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

          if prepared.cameraAssetIsPreStyled,
            let validationError = self?.validateStyledCameraIntermediate(
              rawCameraAsset: cameraAsset,
              styledCameraAsset: AVAsset(url: prepared.url),
              placementSourceRect: prepared.placementSourceRect
            )
          {
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

  private func compatibleOutputTypes(
    for asset: AVAsset,
    preset: String,
    requestedType: AVFileType?
  ) -> (requested: AVFileType?, firstAvailable: AVFileType?, all: [AVFileType]) {
    guard let probe = AVAssetExportSession(asset: asset, presetName: preset) else {
      return (nil, nil, [])
    }

    let all = probe.supportedFileTypes
    let requested = requestedType.flatMap { all.contains($0) ? $0 : nil }
    return (requested, all.first, all)
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
    var context: [String: Any] = [
      "url": url.path,
      "w": w,
      "h": h,
      "nominalFps": track.nominalFrameRate,
      "estimatedDataRate_bps": track.estimatedDataRate,
      "file_bytes": bytes,
      "duration_s": seconds,
      "bitrate_from_file_bps": bpsFromFile,
    ]
    VideoColorPipeline.metadataContext(
      prefix: "track",
      metadata: VideoColorPipeline.assetTrackColorMetadata(track)
    ).forEach { context[$0.key] = $0.value }
    context["workingColorSpace"] = VideoColorPipeline.workingColorSpaceName

    NativeLogger.i(
      "Export", "Exported file info",
      context: context
    )
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

  func _testCleanupStaleExportIntermediates(
    at tempRoot: URL
  ) -> (filesRemoved: Int, bytesReclaimed: Int64) {
    let result = cleanupStaleExportIntermediates(at: tempRoot)
    return (result.filesRemoved, result.bytesReclaimed)
  }

  func _testScreenPrepassTempCapacityError(
    targetSize: CGSize,
    fpsHint: Int32,
    durationSeconds: Double,
    availableCapacityBytes: Int64,
    tempRoot: URL = AppPaths.tempRoot()
  ) -> NSError? {
    screenPrepassTempCapacityError(
      targetSize: targetSize,
      fpsHint: fpsHint,
      durationSeconds: durationSeconds,
      tempRoot: tempRoot,
      availableCapacityBytesOverride: availableCapacityBytes
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
    referenceResult: CompositionBuilder.ExportCompositionResult,
    finalExportURL: URL
  ) -> NSError? {
    guard let validationInfo = referenceResult.validationInfo else { return nil }
    return validateFinalStyledCameraExport(
      referenceAsset: referenceResult.asset,
      referenceComposition: referenceResult.videoComposition,
      validationInfo: validationInfo,
      finalExportAsset: AVAsset(url: finalExportURL)
    )
  }

  func _testRenderFinalExport(
    result: CompositionBuilder.ExportCompositionResult,
    outputURL: URL,
    backgroundColor: Int? = nil,
    backgroundImagePath: String? = nil,
    codec: String = "h264",
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    if result.inlineCameraRenderPlan != nil || result.videoComposition.animationTool != nil {
      runRenderedExportSession(
        asset: result.asset,
        videoComposition: result.videoComposition,
        audioMix: nil,
        outputURL: outputURL,
        outputFileType: .mov,
        codec: codec,
        progressRange: 0.0...1.0,
        onProgress: nil,
        inlineCameraRenderPlan: result.inlineCameraRenderPlan,
        backgroundColor: backgroundColor,
        backgroundImagePath: backgroundImagePath,
        completion: completion
      )
      return
    }

    guard Set(AVAssetExportSession.exportPresets(compatibleWith: result.asset)).contains(
      AVAssetExportPresetHighestQuality
    ),
      let export = AVAssetExportSession(
        asset: result.asset,
        presetName: AVAssetExportPresetHighestQuality
      )
    else {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -35,
            userInfo: [NSLocalizedDescriptionKey: "Test export could not create an AVAssetExportSession"]
          )
        )
      )
      return
    }

    export.videoComposition = result.videoComposition
    export.outputFileType = .mov
    export.outputURL = outputURL
    runExportSession(
      export,
      outputURL: outputURL,
      progressRange: 0.0...1.0,
      onProgress: nil,
      completion: completion
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
