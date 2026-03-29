import AVFoundation
import AppKit

final class CameraChromaKeyRenderer {
  private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
  private lazy var chromaKeyKernel: CIColorKernel? = {
    CIColorKernel(
      source:
        "kernel vec4 chromaKey(__sample s, vec3 keyColor, float strength) {"
        + "  vec3 rgb = s.rgb;"
        + "  float dist = distance(rgb, keyColor);"
        + "  float alpha = (dist < strength) ? 0.0 : 1.0;"
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
    let colorSpace = CGColorSpaceCreateDeviceRGB()
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
          return
        }

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
          return
        }

        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
          failRender(reason: "The chroma-key camera export received an invalid source frame.")
          return
        }

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
          failRender(reason: "The chroma-key camera writer has no pixel buffer pool.")
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
            reason: "The chroma-key camera export could not allocate an output frame.",
            context: ["status": pixelStatus]
          )
          return
        }

        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer).transformed(by: sourceTransform)
        let keyedImage: CIImage
        if let kernel = chromaKeyKernel {
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
          return
        }

        onProgress?(min(1.0, max(0.0, presentationTime.seconds / durationSeconds)))
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
    let color = cameraColor(from: argb).usingColorSpace(.deviceRGB) ?? .green
    return CIVector(
      x: color.redComponent,
      y: color.greenComponent,
      z: color.blueComponent
    )
  }

  private func cameraColor(from argb: Int?) -> NSColor {
    guard let argb else { return .green }
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8) & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    return NSColor(red: r, green: g, blue: b, alpha: a)
  }
}
