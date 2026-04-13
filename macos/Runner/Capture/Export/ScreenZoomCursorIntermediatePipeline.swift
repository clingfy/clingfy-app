import AVFoundation
import AppKit

enum ScreenPrepassExportStage: String {
  case build = "screen_prepass_build"
  case validation = "screen_prepass_validation"
}

func makeScreenPrepassExportError(
  stage: ScreenPrepassExportStage,
  reason: String,
  context: [String: Any] = [:]
) -> NSError {
  var userInfo: [String: Any] = [
    NSLocalizedDescriptionKey: "Screen zoom export could not be rendered. \(reason)",
    "nativeErrorCode": NativeErrorCode.exportError,
    "stage": stage.rawValue,
    "reason": reason,
  ]
  if !context.isEmpty {
    userInfo["context"] = context
  }
  return NSError(domain: "Letterbox.ScreenPrepass", code: 1, userInfo: userInfo)
}

struct ScreenPreparedIntermediate {
  let url: URL
  let temporaryArtifacts: [URL]
}

final class ScreenZoomCursorIntermediatePipeline {
  private let builder = CompositionBuilder()

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

  func requiresPrepass(
    cameraAssetURL: URL?,
    cameraParams: CameraCompositionParams?,
    params: CompositionParams,
    cursorRecording: CursorRecording?
  ) -> Bool {
    guard cameraAssetURL != nil else { return false }
    guard let cameraParams, cameraParams.visible, cameraParams.layoutPreset != .hidden else {
      return false
    }
    guard params.showCursor, params.zoomEnabled else { return false }
    guard let cursorRecording, !cursorRecording.frames.isEmpty else { return false }
    return true
  }

  func prepareIntermediate(
    inputURL: URL,
    params: CompositionParams,
    cursorRecording: CursorRecording,
    isCancelled: @escaping () -> Bool,
    onProgress: ((Double) -> Void)?,
    completion: @escaping (Result<ScreenPreparedIntermediate, Error>) -> Void
  ) {
    let inputAsset = AVAsset(url: inputURL)
    let outputURL = makeScreenIntermediateURL(sourceURL: inputURL)

    var sanitizedParams = CompositionParams(
      targetSize: params.targetSize,
      padding: params.padding,
      cornerRadius: params.cornerRadius,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: params.cursorSize,
      showCursor: params.showCursor,
      zoomEnabled: params.zoomEnabled,
      zoomFactor: params.zoomFactor,
      followStrength: params.followStrength,
      fpsHint: params.fpsHint,
      fitMode: params.fitMode,
      audioGainDb: params.audioGainDb,
      audioVolumePercent: params.audioVolumePercent
    )
    sanitizedParams.zoomSegments = params.zoomSegments
    if sanitizedParams.zoomSegments == nil {
      let autoSegments = ZoomTimelineBuilder.buildSegments(
        cursorRecording: cursorRecording,
        durationSeconds: inputAsset.duration.seconds,
        fps: params.fpsHint > 0 ? Double(params.fpsHint) : 60.0
      )
      sanitizedParams.zoomSegments = autoSegments.map {
        ZoomTimelineSegment(startMs: $0.startMs, endMs: $0.endMs)
      }
    }

    guard
      let prepass = builder.buildScreenPrepass(
        asset: inputAsset,
        params: sanitizedParams,
        cursorRecording: cursorRecording
      )
    else {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeScreenPrepassExportError(
              stage: .build,
              reason: "The screen pre-pass composition could not be created."
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
            makeScreenPrepassExportError(
              stage: .build,
              reason: "The screen pre-pass input has no video track."
            )
          )
        )
      }
      return
    }

    NativeLogger.i(
      "Export",
      "Rendering screen zoom/cursor intermediate",
      context: [
        "input": inputURL.path,
        "output": outputURL.path,
        "target": "\(Int(params.targetSize.width))x\(Int(params.targetSize.height))",
        "cursorFrames": cursorRecording.frames.count,
        "zoomSegments": params.zoomSegments?.count ?? 0,
        "cornerRadius": params.cornerRadius,
      ]
    )

    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
      reader = try AVAssetReader(asset: inputAsset)
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeScreenPrepassExportError(
              stage: .build,
              reason: "The screen pre-pass reader/writer could not be created.",
              context: ["error": error.localizedDescription]
            )
          )
        )
      }
      return
    }

    let readerOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: [videoTrack],
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    readerOutput.videoComposition = prepass.videoComposition
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeScreenPrepassExportError(
              stage: .build,
              reason: "The screen pre-pass reader output could not be configured."
            )
          )
        )
      }
      return
    }
    reader.add(readerOutput)

    let renderSize = prepass.videoComposition.renderSize
    let writerInput: AVAssetWriterInput
    do {
      writerInput = try VideoColorPipeline.makeVideoWriterInput(
        baseOutputSettings: [
          AVVideoCodecKey: AVVideoCodecType.proRes4444,
          AVVideoWidthKey: Int(renderSize.width),
          AVVideoHeightKey: Int(renderSize.height),
        ],
        category: "Export",
        operation: "screen_zoom_cursor_intermediate",
        extraContext: [
          "screenPrepassSelected": true,
          "renderSize": "\(Int(renderSize.width))x\(Int(renderSize.height))",
          "zoomSegmentCount": params.zoomSegments?.count ?? 0,
        ]
      )
    } catch let error as VideoColorPipeline.VideoWriterInputBuildError {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeScreenPrepassExportError(
              stage: .build,
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
            makeScreenPrepassExportError(
              stage: .build,
              reason: "The screen pre-pass writer input could not be created.",
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
            makeScreenPrepassExportError(
              stage: .build,
              reason: "The screen pre-pass writer input could not be configured."
            )
          )
        )
      }
      return
    }
    writer.add(writerInput)

    removeFileIfExists(outputURL)
    let durationSeconds = max(inputAsset.duration.seconds, 0.001)
    let renderQueue = DispatchQueue(label: "Clingfy.ScreenZoomCursorIntermediateRender")
    let renderBounds = CGRect(origin: .zero, size: renderSize)
    let colorSpace = VideoColorPipeline.workingColorSpace
    let ciContext = CIContext(options: [.cacheIntermediates: false])
    var didLogSourceColorMetadata = false
    var completed = false

    func finish(_ result: Result<ScreenPreparedIntermediate, Error>) {
      guard !completed else { return }
      completed = true
      DispatchQueue.main.async {
        completion(result)
      }
    }

    func fail(_ reason: String, context: [String: Any] = [:]) {
      reader.cancelReading()
      writerInput.markAsFinished()
      writer.cancelWriting()
      removeFileIfExists(outputURL)
      finish(
        .failure(
          makeScreenPrepassExportError(
            stage: .build,
            reason: reason,
            context: context
          )
        )
      )
    }

    guard writer.startWriting() else {
      finish(
        .failure(
          makeScreenPrepassExportError(
            stage: .build,
            reason: "The screen pre-pass writer could not start.",
            context: ["error": writer.error?.localizedDescription ?? "unknown"]
          )
        )
      )
      return
    }

    guard reader.startReading() else {
      writer.cancelWriting()
      finish(
        .failure(
          makeScreenPrepassExportError(
            stage: .build,
            reason: "The screen pre-pass reader could not start.",
            context: ["error": reader.error?.localizedDescription ?? "unknown"]
          )
        )
      )
      return
    }

    writer.startSession(atSourceTime: .zero)

    writerInput.requestMediaDataWhenReady(on: renderQueue) {
      while writerInput.isReadyForMoreMediaData {
        if isCancelled() {
          fail("The screen pre-pass was cancelled.")
          return
        }

        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
          guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            fail("The screen pre-pass produced a frame without an image buffer.")
            return
          }

          if !didLogSourceColorMetadata {
            didLogSourceColorMetadata = true
            VideoColorPipeline.logColorMetadata(
              category: "Export",
              message: "Screen pre-pass source color metadata",
              formatDescription: CMSampleBufferGetFormatDescription(sampleBuffer),
              pixelBuffer: pixelBuffer,
              extraContext: [
                "input": inputURL.path,
                "output": outputURL.path,
              ]
            )
          }

          guard let pixelBufferPool = adaptor.pixelBufferPool else {
            fail("The screen pre-pass writer has no pixel buffer pool.")
            return
          }

          var renderedPixelBuffer: CVPixelBuffer?
          let pixelStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &renderedPixelBuffer
          )
          guard pixelStatus == kCVReturnSuccess, let renderedPixelBuffer else {
            fail(
              "The screen pre-pass could not allocate an output frame.",
              context: ["status": pixelStatus]
            )
            return
          }
          VideoColorPipeline.tag(pixelBuffer: renderedPixelBuffer)

          guard let context = self.makeBitmapContext(pixelBuffer: renderedPixelBuffer, colorSpace: colorSpace) else {
            fail("The screen pre-pass could not create a render context.")
            return
          }

          defer {
            CVPixelBufferUnlockBaseAddress(renderedPixelBuffer, [])
          }

          let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
          let sourceBounds = CGRect(
            origin: .zero,
            size: CGSize(
              width: CVPixelBufferGetWidth(pixelBuffer),
              height: CVPixelBufferGetHeight(pixelBuffer)
            )
          )
          guard
            let sourceCGImage = ciContext.createCGImage(
              sourceImage,
              from: sourceBounds,
              format: .RGBA8,
              colorSpace: colorSpace
            )
          else {
            fail("The screen pre-pass could not render the composed frame.")
            return
          }

          context.clear(renderBounds)
          context.interpolationQuality = .high
          context.draw(sourceCGImage, in: renderBounds)

          let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          if !adaptor.append(renderedPixelBuffer, withPresentationTime: presentationTime) {
            fail(
              "The screen pre-pass frame could not be written.",
              context: ["error": writer.error?.localizedDescription ?? "unknown"]
            )
            return
          }

          onProgress?(min(max(presentationTime.seconds / durationSeconds, 0.0), 1.0))
          continue
        }

        switch reader.status {
        case .completed:
          writerInput.markAsFinished()
          writer.finishWriting {
            if writer.status == .completed {
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
                "Screen zoom/cursor intermediate ready",
                context: readyContext
              )
              finish(.success(ScreenPreparedIntermediate(url: outputURL, temporaryArtifacts: [outputURL])))
            } else {
              self.removeFileIfExists(outputURL)
              finish(
                .failure(
                  makeScreenPrepassExportError(
                    stage: .build,
                    reason: "The screen pre-pass writer failed to finish.",
                    context: ["error": writer.error?.localizedDescription ?? "unknown"]
                  )
                )
              )
            }
          }
          return

        case .failed:
          fail(
            "The screen pre-pass reader failed.",
            context: ["error": reader.error?.localizedDescription ?? "unknown"]
          )
          return

        case .cancelled:
          fail("The screen pre-pass reader was cancelled.")
          return

        default:
          fail("The screen pre-pass reader stopped unexpectedly.")
          return
        }
      }
    }
  }

  private func makeScreenIntermediateURL(sourceURL: URL) -> URL {
    let stem = sourceURL.deletingPathExtension().lastPathComponent
    return AppPaths.tempRoot()
      .appendingPathComponent("\(stem).screen-prepass.\(UUID().uuidString)")
      .appendingPathExtension("mov")
  }

  private func removeFileIfExists(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
