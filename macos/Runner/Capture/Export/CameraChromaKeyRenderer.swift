import AVFoundation
import AppKit

final class CameraChromaKeyRenderer {
  private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
  private lazy var chromaKeyKernel: CIColorKernel? = {
    CIColorKernel(
      source:
        "kernel vec4 chromaKey(__sample s, vec3 keyColor, float strength) {"
        + "  vec3 rgb = s.rgb;"
        + "  float greenAdvantage = rgb.g - max(rgb.r, rgb.b);"
        + "  float greenMask = smoothstep(0.02, 0.16 + (strength * 0.20), greenAdvantage);"
        + "  float keyDistance = distance(rgb, keyColor);"
        + "  float similarity = 1.0 - smoothstep(0.18 + (strength * 0.10), 0.90, keyDistance);"
        + "  float matte = clamp(greenMask * (0.85 + (0.15 * similarity)), 0.0, 1.0);"
        + "  float alpha = pow(1.0 - matte, 2.0);"
        + "  return vec4(rgb, alpha * s.a);"
        + "}"
    )
  }()

  func render(
    inputAsset: AVAsset,
    outputURL: URL,
    params: CameraCompositionParams,
    isCancelled: @escaping () -> Bool,
    onProgress: ((Double) -> Void)?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard params.chromaKeyEnabled else {
      DispatchQueue.main.async {
        completion(.success(outputURL))
      }
      return
    }

    guard let videoTrack = inputAsset.tracks(withMediaType: .video).first else {
      DispatchQueue.main.async {
        completion(
          .failure(
            makeAdvancedCameraExportError(
              stage: .styledIntermediateBuild,
              reason: "The chroma-key camera export has no video track."
            )
          )
        )
      }
      return
    }

    let renderSize = orientedSize(for: videoTrack)
    let renderBounds = CGRect(origin: .zero, size: renderSize)
    let colorSpace = VideoColorPipeline.workingColorSpace
    let sourceTransform = normalizedSourceTransform(for: videoTrack)
    let keyColor = chromaKeyColorVector(from: params.chromaKeyColorArgb)

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
              reason: "The chroma-key camera export could not be initialized.",
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
              reason: "The chroma-key camera reader output could not be configured."
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
        operation: "camera_chroma_key_intermediate",
        extraContext: [
          "cameraPrepassSelected": true,
          "chromaKeyEnabled": params.chromaKeyEnabled,
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
              reason: "The chroma-key camera writer input could not be created.",
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
              reason: "The chroma-key camera writer input could not be configured."
            )
          )
        )
      }
      return
    }
    writer.add(writerInput)

    removeFileIfExists(outputURL)
    let durationSeconds = max(inputAsset.duration.seconds, 0.001)
    let renderQueue = DispatchQueue(label: "Clingfy.CameraChromaKeyRender")
    var didLogSourceColorMetadata = false
    var completed = false
    var frameIndex = 0

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
            reason: "The chroma-key camera reader could not start.",
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
            reason: "The chroma-key camera writer could not start.",
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
            failRender(reason: "The chroma-key camera writer has no pixel buffer pool.")
            return false
          }

          let allocation = makePooledPixelBuffer(from: pixelBufferPool)
          if allocation.status == kCVReturnWouldExceedAllocationThreshold {
            NativeLogger.d(
              "ExportMemory",
              "Pixel buffer pool backpressure",
              context: [
                "stage": "screen_prepass",
                "frame": frameIndex,
              ]
            )
            return false
          }

          guard allocation.status == kCVReturnSuccess, let renderedPixelBuffer = allocation.pixelBuffer else {
            failRender(
              reason: "The chroma-key camera export could not allocate an output frame.",
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
                      reason: "The chroma-key camera reader failed.",
                      context: ["error": reader.error?.localizedDescription ?? "unknown"]
                    )
                  )
                )
                return
              }

              if writer.status == .completed {
                onProgress?(1.0)
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
                  "Chroma-key camera intermediate ready",
                  context: readyContext
                )
                finish(.success(outputURL))
              } else {
                finish(
                  .failure(
                    makeAdvancedCameraExportError(
                      stage: .styledIntermediateBuild,
                      reason: "The chroma-key camera writer failed.",
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
            failRender(reason: "The chroma-key camera export received an invalid source frame.")
            return false
          }

          if !didLogSourceColorMetadata {
            didLogSourceColorMetadata = true
            VideoColorPipeline.logColorMetadata(
              category: "Export",
              message: "Chroma-key camera source color metadata",
              formatDescription: CMSampleBufferGetFormatDescription(sampleBuffer),
              pixelBuffer: sourcePixelBuffer,
              extraContext: [
                "output": outputURL.path,
              ]
            )
          }

          let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer).transformed(by: sourceTransform)
          let keyedImage: CIImage
          if let kernel = self.chromaKeyKernel {
            keyedImage =
              kernel.apply(
                extent: sourceImage.extent,
                arguments: [sourceImage, keyColor, Float(params.chromaKeyStrength)]
              ) ?? sourceImage
          } else {
            keyedImage = sourceImage
          }

          CVPixelBufferLockBaseAddress(renderedPixelBuffer, [])
          if let baseAddress = CVPixelBufferGetBaseAddress(renderedPixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(renderedPixelBuffer))
          }
          CVPixelBufferUnlockBaseAddress(renderedPixelBuffer, [])

          self.ciContext.render(
            keyedImage,
            to: renderedPixelBuffer,
            bounds: renderBounds,
            colorSpace: colorSpace
          )

          let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          guard adaptor.append(renderedPixelBuffer, withPresentationTime: presentationTime) else {
            failRender(
              reason: "The chroma-key camera writer rejected a rendered frame.",
              context: ["error": writer.error?.localizedDescription ?? "unknown"]
            )
            return false
          }

          logExportMemoryCheckpoint(stage: "camera_chroma_key_prepass", frameIndex: frameIndex)
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

  private func chromaKeyColorVector(from argb: Int?) -> CIVector {
    let color = cameraColor(from: argb).usingColorSpace(.sRGB) ?? .green
    return CIVector(
      x: color.redComponent,
      y: color.greenComponent,
      z: color.blueComponent
    )
  }

  private func cameraColor(from argb: Int?) -> NSColor {
    VideoColorPipeline.nsColor(fromARGB: argb, defaultColor: .green)
  }
}
