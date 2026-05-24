import AVFoundation
import AppKit

enum ScreenPrepassExportStage: String {
  case build = "screen_prepass_build"
  case validation = "screen_prepass_validation"
}

func makeScreenPrepassExportError(
  stage: ScreenPrepassExportStage,
  nativeErrorCode: String = NativeErrorCode.exportError,
  reason: String,
  context: [String: Any] = [:]
) -> NSError {
  // Disk-full is a user-actionable condition (free up space / pick lower res),
  // not a generic rendering failure — its message stands on its own without
  // the "Screen zoom export could not be rendered." preamble that would
  // otherwise just confuse the user.
  let description: String
  if nativeErrorCode == NativeErrorCode.exportDiskFull {
    description = reason
  } else {
    description = "Screen zoom export could not be rendered. \(reason)"
  }
  var userInfo: [String: Any] = [
    NSLocalizedDescriptionKey: description,
    "nativeErrorCode": nativeErrorCode,
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
  // The screen pre-pass writes an HEVC-with-alpha intermediate (Apple
  // hardware-encoded on Apple Silicon; supports alpha for the rounded-corner
  // mask the final pass composites over the canvas background).
  //
  // Reference bitrate is calibrated for screen content (text, UI, large flat
  // regions — compresses dramatically better than natural video in HEVC) at
  // visually-high quality, scaled linearly by pixel-rate. The cap prevents
  // 8K60 exports from demanding a half-terabyte intermediate; at the cap,
  // HEVC at 150 Mbps still produces an excellent screen recording.
  //
  // Why this was changed from ProRes 4444 (commit history reference): ProRes
  // 4444 at 4K60 ran ~2.6 Gbps and at 8K60 ~10.5 Gbps. That made >4K exports
  // impossible on most disks (a 30-minute 8K60 recording would need ~3 TB of
  // temp space). HEVC-with-alpha is ~50x smaller at comparable visual quality
  // for screen content, with the tradeoff of one extra lossy stage in the
  // pipeline (intermediate + final). For a screen recorder this is the
  // standard tradeoff — the alternative isn't actually a tradeoff.
  private static let storageEstimateReferenceBitrateBps = 12_000_000.0
  private static let storageEstimateReferencePixelsPerSecond = Double(1920 * 1080 * 30)
  private static let storageEstimateMaxBitrateBps = 150_000_000.0
  private static let storageEstimateSafetyMultiplier = 1.30
  private static let storageEstimateSafetyBytes: Int64 = 2 * 1024 * 1024 * 1024

  /// Average bitrate target for the HEVC-with-alpha intermediate at this
  /// render size + fps. Shared between the writer-input setup (so the actual
  /// encoded file roughly matches the estimate) and the disk-capacity
  /// estimator (so the friendly disk-full message is honest).
  static func intermediateAverageBitrateBps(
    renderSize: CGSize,
    fpsHint: Int32
  ) -> Double {
    let pixelsPerSecond =
      Double(max(renderSize.width, 1.0))
      * Double(max(renderSize.height, 1.0))
      * Double(max(fpsHint, 1))
    let scale = pixelsPerSecond / storageEstimateReferencePixelsPerSecond
    let raw = storageEstimateReferenceBitrateBps * max(scale, 0.0)
    return min(raw, storageEstimateMaxBitrateBps)
  }

  private func clearPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
  }

  private func fileSizeBytes(for url: URL) -> Int64 {
    let rawValue =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .int64Value
    return rawValue ?? 0
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

  static func effectiveZoomSegments(
    params: CompositionParams,
    cursorRecording: CursorRecording?,
    durationSeconds: Double?
  ) -> [ZoomTimelineSegment] {
    if let zoomSegments = params.zoomSegments {
      return zoomSegments.filter { $0.endMs > $0.startMs }
    }

    guard let cursorRecording else { return [] }

    let resolvedDuration = max(
      durationSeconds ?? cursorRecording.frames.last?.t ?? 0.0,
      0.0
    )
    guard resolvedDuration > 0 else { return [] }

    let fps = params.fpsHint > 0 ? Double(params.fpsHint) : 60.0
    return ZoomTimelineBuilder.buildSegments(
      cursorRecording: cursorRecording,
      durationSeconds: resolvedDuration,
      fps: fps
    ).map { ZoomTimelineSegment(startMs: $0.startMs, endMs: $0.endMs) }
  }

  static func estimatedTempRequirementBytes(
    renderSize: CGSize,
    fpsHint: Int32,
    durationSeconds: Double
  ) -> Int64 {
    let resolvedDuration = max(durationSeconds, 0.0)
    guard resolvedDuration > 0 else {
      return storageEstimateSafetyBytes
    }

    let estimatedBitrateBps = intermediateAverageBitrateBps(
      renderSize: renderSize, fpsHint: fpsHint
    )
    let estimatedBytes = (estimatedBitrateBps / 8.0) * resolvedDuration
    let withSafety =
      (estimatedBytes * storageEstimateSafetyMultiplier)
      + Double(storageEstimateSafetyBytes)

    guard withSafety.isFinite else { return Int64.max }
    if withSafety >= Double(Int64.max) {
      return Int64.max
    }
    return Int64(withSafety.rounded(.up))
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
    guard params.zoomEnabled else { return false }
    return !Self.effectiveZoomSegments(
      params: params,
      cursorRecording: cursorRecording,
      durationSeconds: cursorRecording?.frames.last?.t
    ).isEmpty
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
    sanitizedParams.zoomSegments = Self.effectiveZoomSegments(
      params: params,
      cursorRecording: cursorRecording,
      durationSeconds: inputAsset.duration.seconds
    )

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
        "zoomSegments": sanitizedParams.zoomSegments?.count ?? 0,
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
    // Pin an average bitrate so the encoded file roughly matches the
    // disk-capacity estimate (the friendly disk-full guard upstream and the
    // encoder share the same formula via intermediateAverageBitrateBps).
    let avgBitrate = Int(
      Self.intermediateAverageBitrateBps(renderSize: renderSize, fpsHint: params.fpsHint)
        .rounded()
    )
    // 2-second GOP gives good seek granularity for any downstream reader
    // without bloating the file. Cap fps lookup to 30 so very low fps inputs
    // still get reasonable keyframe spacing.
    let keyframeInterval = max(Int(params.fpsHint), 30) * 2
    let writerInput: AVAssetWriterInput
    do {
      writerInput = try VideoColorPipeline.makeVideoWriterInput(
        baseOutputSettings: [
          AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
          AVVideoWidthKey: Int(renderSize.width),
          AVVideoHeightKey: Int(renderSize.height),
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: avgBitrate,
            AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
            AVVideoExpectedSourceFrameRateKey: Int(params.fpsHint),
          ],
        ],
        category: "Export",
        operation: "screen_zoom_cursor_intermediate",
        extraContext: [
          "screenPrepassSelected": true,
          "screenPrepassCodec": "hevcWithAlpha",
          "screenPrepassAverageBitrateBps": avgBitrate,
          "renderSize": "\(Int(renderSize.width))x\(Int(renderSize.height))",
          "zoomSegmentCount": sanitizedParams.zoomSegments?.count ?? 0,
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
    let estimatedRequiredTempBytes = Self.estimatedTempRequirementBytes(
      renderSize: renderSize,
      fpsHint: params.fpsHint,
      durationSeconds: durationSeconds
    )
    let renderQueue = DispatchQueue(label: "Clingfy.ScreenZoomCursorIntermediateRender")
    let renderBounds = CGRect(origin: .zero, size: renderSize)
    let colorSpace = VideoColorPipeline.workingColorSpace
    let ciContext = VideoColorPipeline.makeCIContext()
    let stageStart = CFAbsoluteTimeGetCurrent()
    var didLogSourceColorMetadata = false
    var completed = false
    var frameIndex = 0

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
        let shouldContinue = autoreleasepool { () -> Bool in
          if isCancelled() {
            fail("The screen pre-pass was cancelled.")
            return false
          }

          guard let pixelBufferPool = adaptor.pixelBufferPool else {
            fail("The screen pre-pass writer has no pixel buffer pool.")
            return false
          }

          let allocation = makePooledPixelBuffer(from: pixelBufferPool)
          if allocation.status == kCVReturnWouldExceedAllocationThreshold {
            logExportBackpressure(stage: "screen_prepass", frameIndex: frameIndex)
            return false
          }

          guard allocation.status == kCVReturnSuccess, let renderedPixelBuffer = allocation.pixelBuffer else {
            fail(
              "The screen pre-pass could not allocate an output frame.",
              context: ["status": allocation.status]
            )
            return false
          }
          VideoColorPipeline.tag(pixelBuffer: renderedPixelBuffer)

          guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
            switch reader.status {
            case .completed:
              writerInput.markAsFinished()
              writer.finishWriting {
                if writer.status == .completed {
                  logExportStagePerformance(
                    stage: "screen_prepass",
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
                    "Screen zoom/cursor intermediate ready",
                    context: readyContext
                  )
                  finish(
                    .success(
                      ScreenPreparedIntermediate(url: outputURL, temporaryArtifacts: [outputURL])
                    )
                  )
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
              return false

            case .failed:
              fail(
                "The screen pre-pass reader failed.",
                context: ["error": reader.error?.localizedDescription ?? "unknown"]
              )
              return false

            case .cancelled:
              fail("The screen pre-pass reader was cancelled.")
              return false

            default:
              fail("The screen pre-pass reader stopped unexpectedly.")
              return false
            }
          }

          defer {
            CMSampleBufferInvalidate(sampleBuffer)
          }

          guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            fail("The screen pre-pass produced a frame without an image buffer.")
            return false
          }

          let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)

          if !didLogSourceColorMetadata {
            didLogSourceColorMetadata = true
            VideoColorPipeline.logColorMetadata(
              category: "Export",
              message: "Screen pre-pass source color metadata",
              formatDescription: formatDescription,
              pixelBuffer: pixelBuffer,
              extraContext: [
                "input": inputURL.path,
                "output": outputURL.path,
              ]
            )
          }

          let sourceImage = VideoColorPipeline.sourceImage(
            pixelBuffer: pixelBuffer,
            formatDescription: formatDescription
          )
          let sourceBounds = CGRect(
            origin: .zero,
            size: CGSize(
              width: CVPixelBufferGetWidth(pixelBuffer),
              height: CVPixelBufferGetHeight(pixelBuffer)
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
          ciContext.render(
            imageToRender,
            to: renderedPixelBuffer,
            bounds: renderBounds,
            colorSpace: colorSpace
          )

          let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          if !adaptor.append(renderedPixelBuffer, withPresentationTime: presentationTime) {
            let currentTempFileBytes = self.fileSizeBytes(for: outputURL)
            let availableTempBytes = StorageInfoProvider.availableCapacity(for: AppPaths.tempRoot())
            let remainingRequiredBytes = max(estimatedRequiredTempBytes - currentTempFileBytes, 0)
            let reason: String
            if let availableTempBytes, availableTempBytes < remainingRequiredBytes {
              reason = "The screen pre-pass ran out of temporary disk space while writing frames."
            } else {
              reason = "The screen pre-pass frame could not be written."
            }
            fail(
              reason,
              context: [
                "error": writer.error?.localizedDescription ?? "unknown",
                "writerStatus": self.writerStatusDescription(writer.status),
                "currentTempFileBytes": currentTempFileBytes,
                "availableTempBytes": availableTempBytes ?? -1,
                "estimatedRequiredTempBytes": estimatedRequiredTempBytes,
                "estimatedRemainingTempBytes": remainingRequiredBytes,
                "tempPath": AppPaths.tempRoot().path,
              ]
            )
            return false
          }

          logExportMemoryCheckpoint(stage: "screen_prepass", frameIndex: frameIndex)
          frameIndex += 1
          onProgress?(min(max(presentationTime.seconds / durationSeconds, 0.0), 1.0))
          return true
        }

        if !shouldContinue {
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
