import AVFoundation
import AppKit

// Owns camera-only pixel preprocessing before the final two-source composition places the camera.
enum AdvancedCameraExportStage: String {
  case styledIntermediateBuild = "styled_intermediate_build"
  case styledIntermediateValidation = "styled_intermediate_validation"
  case finalOutputValidation = "final_output_validation"
}

func makeAdvancedCameraExportError(
  stage: AdvancedCameraExportStage,
  reason: String,
  context: [String: Any] = [:]
) -> NSError {
  var userInfo: [String: Any] = [
    NSLocalizedDescriptionKey: "Advanced camera export could not be rendered. \(reason)",
    "nativeErrorCode": NativeErrorCode.advancedCameraExportFailed,
    "stage": stage.rawValue,
    "reason": reason,
  ]
  if !context.isEmpty {
    userInfo["context"] = context
  }
  return NSError(domain: "Letterbox.AdvancedCameraExport", code: 1, userInfo: userInfo)
}

struct CameraPreparedIntermediate {
  let url: URL
  let cameraAssetIsPreStyled: Bool
  let temporaryArtifacts: [URL]
  let placementSourceRect: CGRect?
}

final class CameraStyledIntermediatePipeline {
  private struct CameraShadowStyle {
    let opacity: CGFloat
    let radius: CGFloat
    let offset: CGSize
  }

  private struct StyledCameraRenderResult {
    let url: URL
    let placementSourceRect: CGRect
  }

  private let chromaKeyRenderer = CameraChromaKeyRenderer()

  func requiresPrepass(cameraParams: CameraCompositionParams?) -> Bool {
    guard let cameraParams, cameraParams.visible, cameraParams.layoutPreset != .hidden else {
      return false
    }

    return cameraParams.chromaKeyEnabled
  }

  func prepareIntermediate(
    inputURL: URL,
    canvasSize: CGSize,
    params: CameraCompositionParams,
    fpsHint: Int32,
    isCancelled: @escaping () -> Bool,
    onProgress: ((Double) -> Void)?,
    completion: @escaping (Result<CameraPreparedIntermediate, Error>) -> Void
  ) {
    guard requiresPrepass(cameraParams: params) else {
      DispatchQueue.main.async {
        completion(
          .success(
            CameraPreparedIntermediate(
              url: inputURL,
              cameraAssetIsPreStyled: false,
              temporaryArtifacts: [],
              placementSourceRect: nil
            )
          )
        )
      }
      return
    }

    var temporaryArtifacts: [URL] = []

    func cleanupTemporaryArtifacts() {
      for url in temporaryArtifacts {
        if FileManager.default.fileExists(atPath: url.path) {
          try? FileManager.default.removeItem(at: url)
        }
      }
    }

    func finish(_ result: Result<CameraPreparedIntermediate, Error>) {
      DispatchQueue.main.async {
        completion(result)
      }
    }

    func runStyledPass(
      from currentURL: URL,
      progressBase: Double,
      progressSpan: Double
    ) {
      let styledOutputURL = makeStyledCameraIntermediateURL(sourceURL: inputURL)
      temporaryArtifacts.append(styledOutputURL)

      NativeLogger.i(
        "Export",
        "Rendering styled camera intermediate",
        context: [
          "input": currentURL.path,
          "output": styledOutputURL.path,
          "shape": params.shape.rawValue,
          "cornerRadius": params.cornerRadius,
          "borderWidth": params.borderWidth,
          "shadowPreset": params.shadowPreset,
          "chromaKeyEnabled": params.chromaKeyEnabled,
        ]
      )

      renderStyledCameraIntermediate(
        inputAsset: AVAsset(url: currentURL),
        outputURL: styledOutputURL,
        canvasSize: canvasSize,
        params: params,
        isCancelled: isCancelled,
        onProgress: { progress in
          onProgress?(progressBase + (progress * progressSpan))
        }
      ) { result in
        switch result {
        case .success(let styledResult):
          finish(
            .success(
              CameraPreparedIntermediate(
                url: styledResult.url,
                cameraAssetIsPreStyled: true,
                temporaryArtifacts: temporaryArtifacts,
                placementSourceRect: styledResult.placementSourceRect
              )
            )
          )

        case .failure(let error):
          cleanupTemporaryArtifacts()
          finish(.failure(error))
        }
      }
    }

    if params.chromaKeyEnabled {
      let keyedOutputURL = makeChromaKeyIntermediateURL(sourceURL: inputURL)
      temporaryArtifacts.append(keyedOutputURL)

      NativeLogger.i(
        "Export",
        "Rendering chroma-key camera intermediate",
        context: [
          "input": inputURL.path,
          "output": keyedOutputURL.path,
          "strength": params.chromaKeyStrength,
          "colorArgb": params.chromaKeyColorArgb as Any,
        ]
      )

      chromaKeyRenderer.render(
        inputAsset: AVAsset(url: inputURL),
        outputURL: keyedOutputURL,
        params: params,
        isCancelled: isCancelled,
        onProgress: { progress in
          onProgress?(progress * 0.45)
        }
      ) { result in
        switch result {
        case .success(let keyedURL):
          onProgress?(1.0)
          finish(
            .success(
              CameraPreparedIntermediate(
                url: keyedURL,
                cameraAssetIsPreStyled: false,
                temporaryArtifacts: temporaryArtifacts,
                placementSourceRect: nil
              )
            )
          )

        case .failure(let error):
          cleanupTemporaryArtifacts()
          finish(.failure(error))
        }
      }
      return
    }

    runStyledPass(from: inputURL, progressBase: 0.0, progressSpan: 1.0)
  }

  private func makeChromaKeyIntermediateURL(sourceURL: URL) -> URL {
    makeIntermediateURL(sourceURL: sourceURL, suffix: "keyed")
  }

  private func makeStyledCameraIntermediateURL(sourceURL: URL) -> URL {
    makeIntermediateURL(sourceURL: sourceURL, suffix: "styled")
  }

  private func makeIntermediateURL(sourceURL: URL, suffix: String) -> URL {
    let stem = sourceURL.deletingPathExtension().lastPathComponent
    return AppPaths.tempRoot()
      .appendingPathComponent("\(stem).\(suffix).\(UUID().uuidString)")
      .appendingPathExtension("mov")
  }

  private func orientedSize(for track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(
      width: max(1.0, abs(rect.width)),
      height: max(1.0, abs(rect.height))
    )
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
    let colorSpace = VideoColorPipeline.workingColorSpace
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
    VideoColorPipeline.nsColor(fromARGB: argb)
  }

  private func makeStyledShadowImage(
    size: CGSize,
    frameRect: CGRect,
    params: CameraCompositionParams,
    colorSpace: CGColorSpace,
    ciContext: CIContext
  ) -> CGImage? {
    guard let style = shadowStyle(for: params.shadowPreset) else { return nil }
    let bounds = CGRect(origin: .zero, size: size)
    let maskPath = CameraLayoutResolver.maskPath(in: frameRect, params: params)
    guard
      let maskImage = makePathImage(size: size, draw: { context, _ in
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
    frameRect: CGRect,
    params: CameraCompositionParams
  ) -> CGImage? {
    let borderWidth = max(0.0, CGFloat(params.borderWidth))
    guard borderWidth > 0 else { return nil }

    let maskPath = CameraLayoutResolver.maskPath(in: frameRect, params: params)
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
    isCancelled: @escaping () -> Bool,
    onProgress: ((Double) -> Void)?,
    completion: @escaping (Result<StyledCameraRenderResult, Error>) -> Void
  ) {
    guard params.visible, params.layoutPreset != .hidden else {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeAdvancedCameraExportError(
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
            makeAdvancedCameraExportError(
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
            makeAdvancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate resolved to an empty frame."
            )
          )
        )
      }
      return
    }

    let baseFrameSize = CGSize(
      width: max(1.0, ceil(resolution.frame.width)),
      height: max(1.0, ceil(resolution.frame.height))
    )
    let unshiftedBaseFrameRect = CGRect(origin: .zero, size: baseFrameSize)
    let resolvedShadowStyle = shadowStyle(for: params.shadowPreset)
    let paddedRenderBounds: CGRect = {
      guard let style = resolvedShadowStyle else {
        return unshiftedBaseFrameRect
      }

      let blurPadding = ceil(style.radius * 2.0)
      let shadowBleedRect = unshiftedBaseFrameRect
        .insetBy(dx: -blurPadding, dy: -blurPadding)
        .offsetBy(dx: style.offset.width, dy: style.offset.height)
      return unshiftedBaseFrameRect.union(shadowBleedRect).integral
    }()
    let placementSourceRect = unshiftedBaseFrameRect.offsetBy(
      dx: -paddedRenderBounds.minX,
      dy: -paddedRenderBounds.minY
    )
    let renderSize = paddedRenderBounds.size
    let renderBounds = CGRect(origin: .zero, size: renderSize)
    let colorSpace = VideoColorPipeline.workingColorSpace
    let ciContext = VideoColorPipeline.makeCIContext()
    let sourceTransform = normalizedSourceTransform(for: videoTrack)
    let sourceSize = orientedSize(for: videoTrack)
    let fittedDrawRect = CameraLayoutResolver.contentRect(
      for: sourceSize,
      in: placementSourceRect,
      contentMode: params.contentMode
    )
    let maskPath = CameraLayoutResolver.maskPath(in: placementSourceRect, params: params)
    let shadowImage = makeStyledShadowImage(
      size: renderSize,
      frameRect: placementSourceRect,
      params: params,
      colorSpace: colorSpace,
      ciContext: ciContext
    )
    let borderImage = makeStyledBorderImage(
      size: renderSize,
      frameRect: placementSourceRect,
      params: params
    )

    if CameraPlacementDebug.enabled {
      var context: [String: Any] = [
        "shadowPreset": params.shadowPreset,
      ]
      context.merge(
        CameraPlacementDebug.sizeContext(prefix: "baseFrameSize", size: baseFrameSize),
        uniquingKeysWith: { _, new in new }
      )
      context.merge(
        CameraPlacementDebug.rectContext(prefix: "paddedRenderBounds", rect: paddedRenderBounds),
        uniquingKeysWith: { _, new in new }
      )
      context.merge(
        CameraPlacementDebug.rectContext(prefix: "placementSourceRect", rect: placementSourceRect),
        uniquingKeysWith: { _, new in new }
      )
      context.merge(
        CameraPlacementDebug.rectContext(prefix: "fittedDrawRect", rect: fittedDrawRect),
        uniquingKeysWith: { _, new in new }
      )
      if let resolvedShadowStyle {
        context["shadowOpacity"] = resolvedShadowStyle.opacity
        context["shadowRadius"] = resolvedShadowStyle.radius
        context["shadowOffsetX"] = resolvedShadowStyle.offset.width
        context["shadowOffsetY"] = resolvedShadowStyle.offset.height
      }

      NativeLogger.d(
        "CameraPlacementDbg",
        "Styled camera intermediate geometry",
        context: context
      )
    }

    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
      reader = try AVAssetReader(asset: inputAsset)
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeAdvancedCameraExportError(
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
            makeAdvancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate reader output could not be configured."
            )
          )
        )
      }
      return
    }
    reader.add(readerOutput)

    let writerInput: AVAssetWriterInput
    do {
      writerInput = try VideoColorPipeline.makeVideoWriterInput(
        baseOutputSettings: [
          AVVideoCodecKey: AVVideoCodecType.proRes4444,
          AVVideoWidthKey: Int(renderSize.width),
          AVVideoHeightKey: Int(renderSize.height),
        ],
        category: "Export",
        operation: "styled_camera_intermediate",
        extraContext: [
          "cameraPrepassSelected": true,
          "shape": params.shape.rawValue,
          "borderWidth": params.borderWidth,
          "shadowPreset": params.shadowPreset,
          "renderSize": "\(Int(renderSize.width))x\(Int(renderSize.height))",
        ]
      )
    } catch let error as VideoColorPipeline.VideoWriterInputBuildError {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeAdvancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: error.reason,
              context: error.context
            )
          )
        )
      }
      return
    } catch {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeAdvancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate writer input could not be created.",
              context: ["error": error.localizedDescription]
            )
          )
        )
      }
      return
    }
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
            makeAdvancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The styled camera intermediate writer input could not be configured."
            )
          )
        )
      }
      return
    }
    writer.add(writerInput)

    removeFileIfExists(outputURL)
    let durationSeconds = max(inputAsset.duration.seconds, 0.001)
    let renderQueue = DispatchQueue(label: "Clingfy.StyledCameraRender")
    let stageStart = CFAbsoluteTimeGetCurrent()
    var didLogSourceColorMetadata = false
    var completed = false
    var frameIndex = 0

    func finish(_ result: Result<StyledCameraRenderResult, Error>) {
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
          makeAdvancedCameraExportError(
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
          makeAdvancedCameraExportError(
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
          makeAdvancedCameraExportError(
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
        let shouldContinue = autoreleasepool { () -> Bool in
          if isCancelled() {
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
            return false
          }

          guard let pixelBufferPool = adaptor.pixelBufferPool else {
            failRender(reason: "The styled camera intermediate writer has no pixel buffer pool.")
            return false
          }

          let allocation = makePooledPixelBuffer(from: pixelBufferPool)
          if allocation.status == kCVReturnWouldExceedAllocationThreshold {
            logExportBackpressure(stage: "camera_styled_prepass", frameIndex: frameIndex)
            return false
          }

          guard allocation.status == kCVReturnSuccess, let renderedPixelBuffer = allocation.pixelBuffer else {
            failRender(
              reason: "The styled camera intermediate could not allocate an output frame.",
              context: ["status": allocation.status]
            )
            return false
          }
          VideoColorPipeline.tag(pixelBuffer: renderedPixelBuffer)

          guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
            writerInput.markAsFinished()
            writer.finishWriting {
              if reader.status == .failed {
                finish(
                  .failure(
                    makeAdvancedCameraExportError(
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
                logExportStagePerformance(
                  stage: "camera_styled_prepass",
                  frames: frameIndex,
                  startedAt: stageStart
                )
                var readyContext: [String: Any] = [
                  "output": outputURL.path,
                  "renderSize": "\(Int(renderSize.width))x\(Int(renderSize.height))",
                ]
                VideoColorPipeline.metadataContext(
                  prefix: "outputTrack",
                  metadata: VideoColorPipeline.assetTrackColorMetadata(
                    AVAsset(url: outputURL).tracks(withMediaType: .video).first
                  )
                ).forEach { readyContext[$0.key] = $0.value }
                readyContext["workingColorSpace"] = VideoColorPipeline.workingColorSpaceName
                NativeLogger.i(
                  "Export",
                  "Styled camera intermediate ready",
                  context: readyContext
                )
                finish(
                  .success(
                    StyledCameraRenderResult(
                      url: outputURL,
                      placementSourceRect: placementSourceRect
                    )
                  )
                )
              } else {
                finish(
                  .failure(
                    makeAdvancedCameraExportError(
                      stage: .styledIntermediateBuild,
                      reason: "The styled camera intermediate writer failed.",
                      context: ["error": writer.error?.localizedDescription ?? "unknown"]
                    )
                  )
                )
              }
            }
            return false
          }

          defer {
            CMSampleBufferInvalidate(sampleBuffer)
          }

          guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            failRender(reason: "The styled camera intermediate received an invalid source frame.")
            return false
          }

          let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)

          if !didLogSourceColorMetadata {
            didLogSourceColorMetadata = true
            VideoColorPipeline.logColorMetadata(
              category: "Export",
              message: "Styled camera pre-pass source color metadata",
              formatDescription: formatDescription,
              pixelBuffer: sourcePixelBuffer,
              extraContext: [
                "input": inputAsset.description,
                "output": outputURL.path,
              ]
            )
          }

          guard let context = self.makeBitmapContext(pixelBuffer: renderedPixelBuffer, colorSpace: colorSpace) else {
            failRender(reason: "The styled camera intermediate could not create a render context.")
            return false
          }

          defer {
            CVPixelBufferUnlockBaseAddress(renderedPixelBuffer, [])
          }

          let sourceImage = VideoColorPipeline.sourceImage(
            pixelBuffer: sourcePixelBuffer,
            formatDescription: formatDescription
          ).transformed(by: sourceTransform)
          guard
            let sourceCGImage = ciContext.createCGImage(
              sourceImage,
              from: CGRect(origin: .zero, size: sourceSize),
              format: .RGBA8,
              colorSpace: colorSpace
            )
          else {
            failRender(reason: "The styled camera intermediate could not render the camera frame.")
            return false
          }

          context.clear(renderBounds)
          context.interpolationQuality = .high

          if let shadowImage {
            context.draw(shadowImage, in: renderBounds)
          }

          context.saveGState()
          context.addPath(maskPath)
          context.clip()

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
            return false
          }

          logExportMemoryCheckpoint(stage: "camera_styled_prepass", frameIndex: frameIndex)
          frameIndex += 1
          onProgress?(min(1.0, max(0.0, presentationTime.seconds / durationSeconds)))
          return true
        }

        if !shouldContinue {
          return
        }
      }
    }
  }

  private func removeFileIfExists(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

final class InlineCameraRenderer {
  private struct CameraShadowStyle {
    let opacity: CGFloat
    let radius: CGFloat
    let offset: CGSize
  }

  private let renderSize: CGSize
  private let renderBounds: CGRect
  private let colorSpace = VideoColorPipeline.workingColorSpace
  private let ciContext = VideoColorPipeline.makeCIContext()
  private let backgroundImage: CIImage

  init(
    renderSize: CGSize,
    backgroundColor: Int?,
    backgroundImagePath: String?
  ) {
    self.renderSize = renderSize
    self.renderBounds = CGRect(origin: .zero, size: renderSize)
    self.backgroundImage = InlineCameraRenderer.makeBackgroundImage(
      renderSize: renderSize,
      backgroundColor: backgroundColor,
      backgroundImagePath: backgroundImagePath
    )
  }

  func render(
    screenPixelBuffer: CVPixelBuffer,
    screenFormatDescription: CMFormatDescription? = nil,
    cameraPixelBuffer: CVPixelBuffer?,
    cameraFormatDescription: CMFormatDescription? = nil,
    cameraTrack: AVAssetTrack,
    presentationTime: Double,
    plan: CompositionBuilder.InlineCameraRenderPlan,
    to outputPixelBuffer: CVPixelBuffer
  ) {
    let screenImage = VideoColorPipeline.sourceImage(
      pixelBuffer: screenPixelBuffer,
      formatDescription: screenFormatDescription
    )
    let cameraImage = cameraPixelBuffer.map {
      makeCameraSourceImage(
        pixelBuffer: $0,
        formatDescription: cameraFormatDescription,
        track: cameraTrack
      )
    }
    let composedImage = makeCompositedImage(
      screenImage: screenImage,
      cameraSourceImage: cameraImage,
      presentationTime: presentationTime,
      plan: plan
    )

    ciContext.render(
      composedImage,
      to: outputPixelBuffer,
      bounds: renderBounds,
      colorSpace: colorSpace
    )
  }

  func makeCompositedImage(
    screenImage: CIImage,
    cameraSourceImage: CIImage?,
    presentationTime: Double,
    plan: CompositionBuilder.InlineCameraRenderPlan
  ) -> CIImage {
    let normalizedScreenImage = normalizedScreenImage(screenImage)
    let cameraImage = makeStyledCameraImage(
      cameraSourceImage: cameraSourceImage,
      presentationTime: presentationTime,
      plan: plan
    )

    let screenOverBackground = normalizedScreenImage.composited(over: backgroundImage)
    guard let cameraImage else {
      return screenOverBackground
    }

    switch plan.zOrder {
    case .behindScreen:
      return normalizedScreenImage.composited(over: cameraImage.composited(over: backgroundImage))
    case .aboveScreen:
      return cameraImage.composited(over: screenOverBackground)
    }
  }

  func makeCameraSourceImage(
    pixelBuffer: CVPixelBuffer,
    formatDescription: CMFormatDescription? = nil,
    track: AVAssetTrack
  ) -> CIImage {
    let sourceImage = VideoColorPipeline.sourceImage(
      pixelBuffer: pixelBuffer,
      formatDescription: formatDescription
    )
    let normalizedTransform = normalizedSourceTransform(for: track)
    let orientedSize = orientedSize(for: track)
    return sourceImage
      .transformed(by: normalizedTransform)
      .cropped(to: CGRect(origin: .zero, size: orientedSize))
  }

  private func normalizedScreenImage(_ image: CIImage) -> CIImage {
    let extent = image.extent
    guard extent.width > 0.0, extent.height > 0.0 else {
      return CIImage(color: .clear).cropped(to: renderBounds)
    }

    let translated = image.transformed(
      by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )
    let normalizedExtent = translated.extent
    guard abs(normalizedExtent.width - renderSize.width) > 0.0001
      || abs(normalizedExtent.height - renderSize.height) > 0.0001
    else {
      return translated.cropped(to: renderBounds)
    }

    let scaleX = renderSize.width / max(normalizedExtent.width, 1.0)
    let scaleY = renderSize.height / max(normalizedExtent.height, 1.0)
    return translated
      .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
      .cropped(to: renderBounds)
  }

  private func makeStyledCameraImage(
    cameraSourceImage: CIImage?,
    presentationTime: Double,
    plan: CompositionBuilder.InlineCameraRenderPlan
  ) -> CIImage? {
    guard
      let cameraSourceImage,
      let resolvedSample = plan.resolvedSample(at: presentationTime),
      let cameraFrame = resolvedSample.frame?.standardized,
      resolvedSample.opacity > 0.001,
      cameraFrame.width > 0.0,
      cameraFrame.height > 0.0
    else {
      return nil
    }

    let shadowStyle = shadowStyle(for: plan.shadowPreset)
    let paddedBounds: CGRect = {
      guard let shadowStyle else {
        return cameraFrame.integral
      }

      let blurPadding = ceil(shadowStyle.radius * 2.0)
      let shadowBleedRect = cameraFrame
        .insetBy(dx: -blurPadding, dy: -blurPadding)
        .offsetBy(dx: shadowStyle.offset.width, dy: shadowStyle.offset.height)
      return cameraFrame.union(shadowBleedRect).integral
    }()
    let localCameraFrame = cameraFrame.offsetBy(dx: -paddedBounds.minX, dy: -paddedBounds.minY)
    let localBounds = CGRect(origin: .zero, size: paddedBounds.size)
    let cameraParams = cameraParams(for: plan)
    let maskPath = CameraLayoutResolver.maskPath(in: localCameraFrame, params: cameraParams)
    let sourceRect = plan.sourceRect?.standardized
    let sourceImage = sourceRect.map { cameraSourceImage.cropped(to: $0) } ?? cameraSourceImage
    let sourceSize = sourceRect?.size ?? plan.sourceSize
    let fittedDrawRect = CameraLayoutResolver.contentRect(
      for: sourceSize,
      in: localCameraFrame,
      contentMode: plan.contentMode
    )

    guard
      let sourceCGImage = ciContext.createCGImage(
        sourceImage,
        from: sourceImage.extent,
        format: .RGBA8,
        colorSpace: colorSpace
      ),
      let context = CGContext(
        data: nil,
        width: max(1, Int(ceil(localBounds.width))),
        height: max(1, Int(ceil(localBounds.height))),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else {
      return nil
    }

    context.clear(localBounds)
    context.interpolationQuality = .high

    if let shadowImage = makeStyledShadowImage(
      size: localBounds.size,
      frameRect: localCameraFrame,
      params: cameraParams
    ) {
      context.draw(shadowImage, in: localBounds)
    }

    context.saveGState()
    context.addPath(maskPath)
    context.clip()

    if plan.mirror {
      context.translateBy(x: fittedDrawRect.minX + fittedDrawRect.maxX, y: 0)
      context.scaleBy(x: -1.0, y: 1.0)
    }

    context.draw(sourceCGImage, in: fittedDrawRect)
    context.restoreGState()

    if let borderImage = makeStyledBorderImage(
      size: localBounds.size,
      frameRect: localCameraFrame,
      params: cameraParams
    ) {
      context.draw(borderImage, in: localBounds)
    }

    guard let renderedImage = context.makeImage() else {
      return nil
    }

    return CIImage(cgImage: renderedImage)
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: resolvedSample.opacity),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
      )
      .transformed(by: CGAffineTransform(translationX: paddedBounds.minX, y: paddedBounds.minY))
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

  private func cameraParams(
    for plan: CompositionBuilder.InlineCameraRenderPlan
  ) -> CameraCompositionParams {
    CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: plan.shape,
      cornerRadius: plan.cornerRadius,
      opacity: plan.opacity,
      mirror: plan.mirror,
      contentMode: plan.contentMode,
      zoomBehavior: .fixed,
      borderWidth: plan.borderWidth,
      borderColorArgb: plan.borderColorArgb,
      shadowPreset: plan.shadowPreset,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
  }

  private func makeStyledShadowImage(
    size: CGSize,
    frameRect: CGRect,
    params: CameraCompositionParams
  ) -> CGImage? {
    guard let shadowStyle = shadowStyle(for: params.shadowPreset) else { return nil }
    let bounds = CGRect(origin: .zero, size: size)
    let maskPath = CameraLayoutResolver.maskPath(in: frameRect, params: params)
    guard
      let maskImage = makePathImage(size: size, draw: { context, _ in
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(maskPath)
        context.fillPath()
      })
    else {
      return nil
    }

    let clearImage = CIImage(color: CIColor.clear).cropped(to: bounds)
    let blurredMask = CIImage(cgImage: maskImage)
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shadowStyle.radius])
      .transformed(by: CGAffineTransform(translationX: shadowStyle.offset.width, y: shadowStyle.offset.height))
      .cropped(to: bounds)
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: shadowStyle.opacity),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
      )
      .composited(over: clearImage)

    return ciContext.createCGImage(blurredMask, from: bounds, format: .RGBA8, colorSpace: colorSpace)
  }

  private func makeStyledBorderImage(
    size: CGSize,
    frameRect: CGRect,
    params: CameraCompositionParams
  ) -> CGImage? {
    let borderWidth = max(0.0, CGFloat(params.borderWidth))
    guard borderWidth > 0.0 else { return nil }

    let maskPath = CameraLayoutResolver.maskPath(in: frameRect, params: params)
    let borderColor = VideoColorPipeline.nsColor(fromARGB: params.borderColorArgb).cgColor

    return makePathImage(size: size, draw: { context, _ in
      context.setLineWidth(borderWidth)
      context.setStrokeColor(borderColor)
      context.addPath(maskPath)
      context.strokePath()
    })
  }

  private func makePathImage(
    size: CGSize,
    draw: (CGContext, CGRect) -> Void
  ) -> CGImage? {
    let width = max(1, Int(ceil(size.width)))
    let height = max(1, Int(ceil(size.height)))
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

  private func orientedSize(for track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(
      width: max(1.0, abs(rect.width)),
      height: max(1.0, abs(rect.height))
    )
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

  private static func makeBackgroundImage(
    renderSize: CGSize,
    backgroundColor: Int?,
    backgroundImagePath: String?
  ) -> CIImage {
    let bounds = CGRect(origin: .zero, size: renderSize)

    if let backgroundImagePath,
      let image = NSImage(contentsOfFile: backgroundImagePath),
      let cgImage = image.cgImageForLayer()
    {
      let width = max(1, Int(ceil(renderSize.width)))
      let height = max(1, Int(ceil(renderSize.height)))
      let colorSpace = VideoColorPipeline.workingColorSpace
      if let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      ) {
        let imageRect = CGRect(origin: .zero, size: CGSize(width: cgImage.width, height: cgImage.height))
        let fillScale = max(
          bounds.width / max(imageRect.width, 1.0),
          bounds.height / max(imageRect.height, 1.0)
        )
        let drawSize = CGSize(
          width: imageRect.width * fillScale,
          height: imageRect.height * fillScale
        )
        let drawRect = CGRect(
          x: (bounds.width - drawSize.width) / 2.0,
          y: (bounds.height - drawSize.height) / 2.0,
          width: drawSize.width,
          height: drawSize.height
        )
        context.draw(cgImage, in: drawRect)
        if let rendered = context.makeImage() {
          return CIImage(cgImage: rendered)
        }
      }
    }

    let fallbackColor = VideoColorPipeline.cgColor(
      fromARGB: backgroundColor,
      defaultColor: CGColor.black
    )
    return CIImage(color: CIColor(cgColor: fallbackColor)).cropped(to: bounds)
  }
}
