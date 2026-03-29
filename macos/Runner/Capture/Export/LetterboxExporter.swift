import AVFoundation
import AppKit
import QuartzCore

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

  private enum AdvancedCameraExportStage: String {
    case styledIntermediateBuild = "styled_intermediate_build"
    case styledIntermediateValidation = "styled_intermediate_validation"
    case finalOutputValidation = "final_output_validation"
  }

  private struct CameraShadowStyle {
    let opacity: CGFloat
    let radius: CGFloat
    let offset: CGSize
  }

  private let builder = CompositionBuilder()
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
    temporaryArtifacts.append(url)
  }

  private func cleanupTemporaryArtifacts() {
    let fileManager = FileManager.default
    for url in temporaryArtifacts {
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

  private func advancedCameraExportError(
    stage: AdvancedCameraExportStage,
    reason: String,
    context: [String: Any] = [:]
  ) -> NSError {
    var userInfo: [String: Any] = [
      NSLocalizedDescriptionKey: "Advanced camera styling could not be rendered for export. \(reason)",
      "nativeErrorCode": NativeErrorCode.advancedCameraExportFailed,
      "stage": stage.rawValue,
      "reason": reason,
    ]
    if !context.isEmpty {
      userInfo["context"] = context
    }
    return NSError(domain: "Letterbox.AdvancedCameraExport", code: 1, userInfo: userInfo)
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

  private func validateStyledCameraIntermediate(
    rawCameraAsset: AVAsset,
    styledCameraAsset: AVAsset
  ) -> NSError? {
    do {
      let rawImage = try sampleFrameImage(asset: rawCameraAsset)
      let styledImage = try sampleFrameImage(asset: styledCameraAsset)

      guard
        let rawMetrics = analyzeFrameContent(rawImage, ignoreTransparentPixels: false),
        let styledMetrics = analyzeFrameContent(styledImage, ignoreTransparentPixels: true)
      else {
        return advancedCameraExportError(
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
        return advancedCameraExportError(
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
      return advancedCameraExportError(
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
    cameraParams: CameraCompositionParams
  ) -> NSError? {
    let resolution = CameraLayoutResolver.effectiveFrame(
      canvasSize: canvasSize,
      params: cameraParams
    )
    guard resolution.shouldRender else { return nil }

    do {
      let styledImage = try sampleFrameImage(asset: styledCameraAsset)
      let finalImage = try sampleFrameImage(asset: finalExportAsset)

      guard let styledMetrics = analyzeFrameContent(styledImage, ignoreTransparentPixels: true) else {
        return advancedCameraExportError(
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
        return advancedCameraExportError(
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
        return advancedCameraExportError(
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
      return advancedCameraExportError(
        stage: .finalOutputValidation,
        reason: "The final export validator could not sample the exported file.",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func orientedSize(for track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }

  private func normalizedSourceTransform(for track: AVAssetTrack) -> CGAffineTransform {
    let orientedRect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return track.preferredTransform.concatenating(
      CGAffineTransform(
        translationX: -orientedRect.minX,
        y: -orientedRect.minY
      )
    )
  }

  private func drawRect(
    for sourceSize: CGSize,
    in bounds: CGRect,
    contentMode: CameraContentMode
  ) -> CGRect {
    let safeSourceWidth = max(sourceSize.width, 1.0)
    let safeSourceHeight = max(sourceSize.height, 1.0)
    let scaleX = bounds.width / safeSourceWidth
    let scaleY = bounds.height / safeSourceHeight
    let scale = contentMode == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
    let width = safeSourceWidth * scale
    let height = safeSourceHeight * scale
    return CGRect(
      x: bounds.minX + ((bounds.width - width) / 2.0),
      y: bounds.minY + ((bounds.height - height) / 2.0),
      width: width,
      height: height
    )
  }

  private func makeBitmapContext(
    pixelBuffer: CVPixelBuffer,
    colorSpace: CGColorSpace
  ) -> CGContext? {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      return nil
    }

    let context = CGContext(
      data: baseAddress,
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    )

    if context == nil {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    return context
  }

  private func makePathImage(
    size: CGSize,
    draw: (CGContext, CGRect) -> Void
  ) -> CGImage? {
    let width = max(1, Int(ceil(size.width)))
    let height = max(1, Int(ceil(size.height)))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else {
      return nil
    }

    let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
    context.clear(bounds)
    draw(context, bounds)
    return context.makeImage()
  }

  private func shadowStyle(for preset: Int) -> CameraShadowStyle? {
    switch preset {
    case 1:
      return CameraShadowStyle(opacity: 0.18, radius: 10, offset: CGSize(width: 0, height: -2))
    case 2:
      return CameraShadowStyle(opacity: 0.24, radius: 16, offset: CGSize(width: 0, height: -4))
    case 3:
      return CameraShadowStyle(opacity: 0.32, radius: 22, offset: CGSize(width: 0, height: -6))
    default:
      return nil
    }
  }

  private func cameraColor(from argb: Int?) -> NSColor {
    guard let argb else { return .white }
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8) & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    return NSColor(red: r, green: g, blue: b, alpha: a)
  }

  private func makeStyledShadowImage(
    size: CGSize,
    params: CameraCompositionParams,
    colorSpace: CGColorSpace,
    ciContext: CIContext
  ) -> CGImage? {
    guard let style = shadowStyle(for: params.shadowPreset) else { return nil }
    let bounds = CGRect(origin: .zero, size: size)
    let maskPath = CameraLayoutResolver.maskPath(in: bounds, params: params)
    guard
      let maskImage = makePathImage(size: size, draw: { context, pathBounds in
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(maskPath)
        context.fillPath()
      })
    else {
      return nil
    }

    let clearImage = CIImage(color: CIColor.clear).cropped(to: bounds)
    let blurredMask = CIImage(cgImage: maskImage)
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: style.radius])
      .transformed(by: CGAffineTransform(translationX: style.offset.width, y: style.offset.height))
      .cropped(to: bounds)
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: style.opacity),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
      )
      .composited(over: clearImage)

    return ciContext.createCGImage(blurredMask, from: bounds, format: .RGBA8, colorSpace: colorSpace)
  }

  private func makeStyledBorderImage(
    size: CGSize,
    params: CameraCompositionParams
  ) -> CGImage? {
    let borderWidth = max(0.0, CGFloat(params.borderWidth))
    guard borderWidth > 0 else { return nil }

    let bounds = CGRect(origin: .zero, size: size)
    let maskPath = CameraLayoutResolver.maskPath(in: bounds, params: params)
    let borderColor = cameraColor(from: params.borderColorArgb).cgColor

    return makePathImage(size: size, draw: { context, _ in
      context.setLineWidth(borderWidth)
      context.setStrokeColor(borderColor)
      context.addPath(maskPath)
      context.strokePath()
    })
  }

  private func renderStyledCameraIntermediate(
    inputAsset: AVAsset,
    outputURL: URL,
    canvasSize: CGSize,
    params: CameraCompositionParams,
    fpsHint: Int32,
    onProgress: ((Double) -> Void)?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard params.visible, params.layoutPreset != .hidden else {
      DispatchQueue.main.async {
        completion(
          .failure(
            self.advancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate could not be built."
            )
          )
        )
      }
      return
    }

    guard let videoTrack = inputAsset.tracks(withMediaType: .video).first else {
      DispatchQueue.main.async {
        completion(
          .failure(
            self.advancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate has no video track."
            )
          )
        )
      }
      return
    }

    let resolution = CameraLayoutResolver.effectiveFrame(canvasSize: canvasSize, params: params)
    guard resolution.shouldRender else {
      DispatchQueue.main.async {
        completion(
          .failure(
            self.advancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate resolved to an empty frame."
            )
          )
        )
      }
      return
    }

    let renderSize = CGSize(
      width: max(1.0, ceil(resolution.frame.width)),
      height: max(1.0, ceil(resolution.frame.height))
    )
    let renderBounds = CGRect(origin: .zero, size: renderSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ciContext = CIContext(options: [.cacheIntermediates: false])
    let sourceTransform = normalizedSourceTransform(for: videoTrack)
    let sourceSize = orientedSize(for: videoTrack)
    let fittedDrawRect = drawRect(
      for: sourceSize,
      in: renderBounds,
      contentMode: params.contentMode
    )
    let maskPath = CameraLayoutResolver.maskPath(in: renderBounds, params: params)
    let shadowImage = makeStyledShadowImage(
      size: renderSize,
      params: params,
      colorSpace: colorSpace,
      ciContext: ciContext
    )
    let borderImage = makeStyledBorderImage(size: renderSize, params: params)

    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
      reader = try AVAssetReader(asset: inputAsset)
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
      DispatchQueue.main.async {
        completion(
          .failure(
            self.advancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate could not be initialized.",
              context: ["error": error.localizedDescription]
            )
          )
        )
      }
      return
    }

    let readerOutput = AVAssetReaderTrackOutput(
      track: videoTrack,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else {
      DispatchQueue.main.async {
        completion(
          .failure(
            self.advancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate reader output could not be configured."
            )
          )
        )
      }
      return
    }
    reader.add(readerOutput)

    let writerInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes4444,
        AVVideoWidthKey: Int(renderSize.width),
        AVVideoHeightKey: Int(renderSize.height),
      ]
    )
    writerInput.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: writerInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(renderSize.width),
        kCVPixelBufferHeightKey as String: Int(renderSize.height),
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ]
    )

    guard writer.canAdd(writerInput) else {
      DispatchQueue.main.async {
        completion(
          .failure(
            self.advancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate writer input could not be configured."
            )
          )
        )
      }
      return
    }
    writer.add(writerInput)

    self.removeFileIfExists(outputURL)
    let durationSeconds = max(inputAsset.duration.seconds, 0.001)
    let renderQueue = DispatchQueue(label: "Clingfy.StyledCameraRender")
    var completed = false

    func finish(_ result: Result<URL, Error>) {
      guard !completed else { return }
      completed = true
      DispatchQueue.main.async {
        completion(result)
      }
    }

    func failRender(reason: String, context: [String: Any] = [:]) {
      reader.cancelReading()
      writerInput.markAsFinished()
      writer.cancelWriting()
      finish(
        .failure(
          advancedCameraExportError(
            stage: .styledIntermediateBuild,
            reason: reason,
            context: context
          )
        )
      )
    }

    guard reader.startReading() else {
      finish(
        .failure(
          advancedCameraExportError(
            stage: .styledIntermediateBuild,
            reason: "The styled camera intermediate reader could not start.",
            context: ["error": reader.error?.localizedDescription ?? "unknown"]
          )
        )
      )
      return
    }

    guard writer.startWriting() else {
      finish(
        .failure(
          advancedCameraExportError(
            stage: .styledIntermediateBuild,
            reason: "The styled camera intermediate writer could not start.",
            context: ["error": writer.error?.localizedDescription ?? "unknown"]
          )
        )
      )
      return
    }

    writer.startSession(atSourceTime: .zero)

    writerInput.requestMediaDataWhenReady(on: renderQueue) { [weak self] in
      guard let self else { return }

      while writerInput.isReadyForMoreMediaData {
        if self.isCancelled {
          reader.cancelReading()
          writerInput.markAsFinished()
          writer.cancelWriting()
          finish(
            .failure(
              NSError(
                domain: "Letterbox",
                code: -999,
                userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]
              )
            )
          )
          return
        }

        guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
          writerInput.markAsFinished()
          writer.finishWriting {
            if reader.status == .failed {
              finish(
                .failure(
                  self.advancedCameraExportError(
                    stage: .styledIntermediateBuild,
                    reason: "The styled camera intermediate reader failed.",
                    context: ["error": reader.error?.localizedDescription ?? "unknown"]
                  )
                )
              )
              return
            }

            if writer.status == .completed {
              onProgress?(1.0)
              finish(.success(outputURL))
            } else {
              finish(
                .failure(
                  self.advancedCameraExportError(
                    stage: .styledIntermediateBuild,
                    reason: "The styled camera intermediate writer failed.",
                    context: ["error": writer.error?.localizedDescription ?? "unknown"]
                  )
                )
              )
            }
          }
          return
        }

        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
          failRender(reason: "The styled camera intermediate received an invalid source frame.")
          return
        }

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
          failRender(reason: "The styled camera intermediate writer has no pixel buffer pool.")
          return
        }

        var renderedPixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferPoolCreatePixelBuffer(
          kCFAllocatorDefault,
          pixelBufferPool,
          &renderedPixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let renderedPixelBuffer else {
          failRender(
            reason: "The styled camera intermediate could not allocate an output frame.",
            context: ["status": pixelStatus]
          )
          return
        }

        guard let context = self.makeBitmapContext(pixelBuffer: renderedPixelBuffer, colorSpace: colorSpace) else {
          failRender(reason: "The styled camera intermediate could not create a render context.")
          return
        }

        defer {
          CVPixelBufferUnlockBaseAddress(renderedPixelBuffer, [])
        }

        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer).transformed(by: sourceTransform)
        guard
          let sourceCGImage = ciContext.createCGImage(
            sourceImage,
            from: CGRect(origin: .zero, size: sourceSize),
            format: .RGBA8,
            colorSpace: colorSpace
          )
        else {
          failRender(reason: "The styled camera intermediate could not render the camera frame.")
          return
        }

        context.clear(renderBounds)
        context.interpolationQuality = .high

        if let shadowImage {
          context.draw(shadowImage, in: renderBounds)
        }

        context.saveGState()
        context.addPath(maskPath)
        context.clip()
        context.setAlpha(CGFloat(max(0.0, min(1.0, params.opacity))))

        if params.mirror {
          context.translateBy(x: fittedDrawRect.minX + fittedDrawRect.maxX, y: 0)
          context.scaleBy(x: -1.0, y: 1.0)
        }

        context.draw(sourceCGImage, in: fittedDrawRect)
        context.restoreGState()

        if let borderImage {
          context.draw(borderImage, in: renderBounds)
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard adaptor.append(renderedPixelBuffer, withPresentationTime: presentationTime) else {
          failRender(
            reason: "The styled camera intermediate writer rejected a rendered frame.",
            context: ["error": writer.error?.localizedDescription ?? "unknown"]
          )
          return
        }

        onProgress?(min(1.0, max(0.0, presentationTime.seconds / durationSeconds)))
      }
    }
  }

  private func shouldUseStyledCameraIntermediate(cameraParams: CameraCompositionParams?) -> Bool {
    guard let cameraParams, cameraParams.visible, cameraParams.layoutPreset != .hidden else {
      return false
    }

    if cameraParams.borderWidth > 0 || cameraParams.shadowPreset > 0 {
      return true
    }

    switch cameraParams.shape {
    case .square:
      return false
    case .roundedRect:
      return cameraParams.cornerRadius > 0
    case .circle, .squircle:
      return true
    }
  }

  private func makeStyledCameraIntermediateURL(sourceURL: URL) -> URL {
    let stem = sourceURL.deletingPathExtension().lastPathComponent
    return AppPaths.tempRoot()
      .appendingPathComponent("\(stem).styled.\(UUID().uuidString)")
      .appendingPathExtension("mov")
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
    inputURL: URL,
    cameraInputURL: URL? = nil,
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

    let asset = AVAsset(url: inputURL)

    // Load cursor recording if needed (gracefully handle missing cursor file)
    var cursorRecording: CursorRecording?
    if showCursor {
      let cursorDataURL = AppPaths.cursorSidecarURL(for: inputURL)
      if let data = try? Data(contentsOf: cursorDataURL),
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
          context: ["expectedPath": cursorDataURL.lastPathComponent])
      }
    }

    // Load manual segments
    let manualURL = AppPaths.zoomManualSidecarURL(for: inputURL)
    var manualSegments: [ZoomTimelineSegment] = []
    var overriddenAutoIds: Set<String> = []

    if let data = try? Data(contentsOf: manualURL),
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
        "input": inputURL.path,
        "output": outputURL.path,
        "target": "\(Int(target.width))x\(Int(target.height))",
        "fpsHint": fpsHint,
        "format": format,
        "codec": codec,
      ])

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

    func beginFinalExport(
      resolvedCameraInputURL: URL?,
      progressRange: ClosedRange<Double>,
      cameraAssetIsPreStyled: Bool
    ) {
      let cameraAsset = resolvedCameraInputURL.map(AVAsset.init(url:))

      guard
        let comp = builder.buildExport(
          asset: asset,
          cameraAsset: cameraAsset,
          params: params,
          cameraParams: cameraParams,
          cursorRecording: cursorRecording,
          cameraAssetIsPreStyled: cameraAssetIsPreStyled
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
          "input": inputURL.path,
          "cameraInput": resolvedCameraInputURL?.path ?? "nil",
          "cameraAssetIsPreStyled": cameraAssetIsPreStyled,
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
              cameraParams: cameraParams
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

    if let cameraInputURL, shouldUseStyledCameraIntermediate(cameraParams: cameraParams) {
      let cameraAsset = AVAsset(url: cameraInputURL)
      let styledOutputURL = makeStyledCameraIntermediateURL(sourceURL: cameraInputURL)
      registerTemporaryArtifact(styledOutputURL)

      NativeLogger.i(
        "Export",
        "Rendering styled camera intermediate",
        context: [
          "input": cameraInputURL.path,
          "output": styledOutputURL.path,
          "shape": cameraParams?.shape.rawValue ?? "nil",
          "cornerRadius": cameraParams?.cornerRadius ?? 0,
          "borderWidth": cameraParams?.borderWidth ?? 0,
          "shadowPreset": cameraParams?.shadowPreset ?? 0,
        ]
      )

      if FileManager.default.fileExists(atPath: styledOutputURL.path) {
        try? FileManager.default.removeItem(at: styledOutputURL)
      }

      renderStyledCameraIntermediate(
        inputAsset: cameraAsset,
        outputURL: styledOutputURL,
        canvasSize: target,
        params: cameraParams ?? .hidden,
        fpsHint: fpsHint,
        onProgress: { progress in
          onProgress?(progress * 0.35)
        }
      ) { [weak self] result in
        switch result {
        case .success(let styledURL):
          if let validationError = self?.validateStyledCameraIntermediate(
            rawCameraAsset: cameraAsset,
            styledCameraAsset: AVAsset(url: styledURL)
          ) {
            NativeLogger.e(
              "Export",
              "Styled camera intermediate validation failed",
              context: validationError.userInfo
            )
            self?.cleanupTemporaryArtifacts()
            completion(.failure(validationError))
            return
          }

          NativeLogger.i(
            "Export",
            "Styled camera intermediate ready",
            context: ["path": styledURL.path]
          )
          beginFinalExport(
            resolvedCameraInputURL: styledURL,
            progressRange: 0.35...1.0,
            cameraAssetIsPreStyled: true
          )
        case .failure(let error):
          self?.cleanupTemporaryArtifacts()
          completion(.failure(error))
        }
      }
      return
    }

    beginFinalExport(
      resolvedCameraInputURL: cameraInputURL,
      progressRange: 0.0...1.0,
      cameraAssetIsPreStyled: false
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
  func _testShouldUseStyledCameraIntermediate(cameraParams: CameraCompositionParams?) -> Bool {
    shouldUseStyledCameraIntermediate(cameraParams: cameraParams)
  }

  func _testRenderStyledCameraIntermediate(
    inputURL: URL,
    outputURL: URL,
    canvasSize: CGSize,
    cameraParams: CameraCompositionParams,
    fpsHint: Int32,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    renderStyledCameraIntermediate(
      inputAsset: AVAsset(url: inputURL),
      outputURL: outputURL,
      canvasSize: canvasSize,
      params: cameraParams,
      fpsHint: fpsHint,
      onProgress: nil,
      completion: completion
    )
  }

  func _testValidateStyledCameraIntermediate(
    rawCameraURL: URL,
    styledCameraURL: URL
  ) -> NSError? {
    validateStyledCameraIntermediate(
      rawCameraAsset: AVAsset(url: rawCameraURL),
      styledCameraAsset: AVAsset(url: styledCameraURL)
    )
  }

  func _testValidateFinalStyledCameraExport(
    styledCameraURL: URL,
    finalExportURL: URL,
    canvasSize: CGSize,
    cameraParams: CameraCompositionParams
  ) -> NSError? {
    validateFinalStyledCameraExport(
      styledCameraAsset: AVAsset(url: styledCameraURL),
      finalExportAsset: AVAsset(url: finalExportURL),
      canvasSize: canvasSize,
      cameraParams: cameraParams
    )
  }
#endif

}
