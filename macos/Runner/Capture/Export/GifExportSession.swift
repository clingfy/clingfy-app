import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Transcodes a fully-composited video (the exporter's normal MOV/MP4 output)
/// into an animated GIF. Runs off the main thread, streaming one frame at a
/// time: decimate to `GifExportPolicy.targetFps`, downscale to the long-edge
/// cap, and feed frames to `GifEncoder`.
///
/// Why transcode the rendered video instead of tapping the export mid-flight:
/// color grade and the inline camera are baked in the export's per-frame compose
/// tail, not in its `AVVideoComposition`, so the *only* source of
/// fully-composited frames is the finished video. Transcoding it reuses the
/// entire (tested) render pipeline and keeps `LetterboxExporter` untouched. See
/// `docs/decisions/macos-gif-export.md`.
final class GifExportSession {
  struct GifExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private let workQueue = DispatchQueue(label: "com.clingfy.gif-export", qos: .userInitiated)
  /// Must be the pipeline's context, not a bare `CIContext`. Core Image
  /// defaults to a LINEAR working space, and
  /// `ColorTransferFunctions.decodeFromExport` — like every kernel in that
  /// file — assumes it is handed gamma-encoded sRGB samples.
  /// `VideoColorPipeline.makeCIContext()` is what makes that true.
  private let ciContext = VideoColorPipeline.makeCIContext()
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  /// Transcode `sourceVideoURL` into `outputURL` (`.gif`). `onProgress` (0…1)
  /// and `completion` are delivered on the main queue.
  func run(
    sourceVideoURL: URL,
    outputURL: URL,
    maxLongEdge: CGFloat = GifExportPolicy.defaultMaxLongEdge,
    onProgress: ((Double) -> Void)?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    workQueue.async {
      let result = self.transcode(
        sourceVideoURL: sourceVideoURL, outputURL: outputURL,
        maxLongEdge: maxLongEdge, onProgress: onProgress)
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func failure(_ message: String) -> Result<URL, Error> {
    .failure(GifExportError(message: message))
  }

  private func transcode(
    sourceVideoURL: URL, outputURL: URL, maxLongEdge: CGFloat,
    onProgress: ((Double) -> Void)?
  ) -> Result<URL, Error> {
    let asset = AVAsset(url: sourceVideoURL)
    guard let track = asset.tracks(withMediaType: .video).first else {
      return failure("The rendered video has no video track to convert to GIF.")
    }
    let canvasSize = orientedSize(track)
    let gifSize = GifExportPolicy.renderSize(canvasSize: canvasSize, maxLongEdge: maxLongEdge)
    let durationSeconds = max(asset.duration.seconds, 0.0001)

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      return failure("Could not read the rendered video: \(error.localizedDescription)")
    }
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      return failure("Could not attach the GIF frame reader.")
    }
    reader.add(output)
    guard reader.startReading() else {
      return failure(reader.error?.localizedDescription ?? "The GIF frame reader failed to start.")
    }

    let encoder: GifEncoder
    do {
      encoder = try GifEncoder(url: outputURL)
    } catch {
      reader.cancelReading()
      return failure("Could not create the GIF file: \(error.localizedDescription)")
    }

    var emitTarget = GifExportPolicy.emitTargetStart
    var keptCount = 0

    readLoop: while reader.status == .reading {
      if isCancelled {
        reader.cancelReading()
        encoder.cancel()
        return failure("Export cancelled")
      }
      guard let sample = output.copyNextSampleBuffer() else { break }

      let ok: Bool = autoreleasepool {
        defer { CMSampleBufferInvalidate(sample) }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let tsHns = Int64((pts.seconds * 10_000_000).rounded())
        // Decimate to the target fps on the ideal grid.
        guard
          GifExportPolicy.shouldKeepGifFrame(frameTsHns: tsHns, emitTargetHns: emitTarget),
          let buffer = CMSampleBufferGetImageBuffer(sample)
        else {
          return true  // dropped by decimation, or a frame with no image buffer
        }
        guard let cgImage = makeDownscaledCGImage(from: buffer, to: gifSize) else {
          return false
        }
        do {
          try encoder.append(cgImage, timestampHns: tsHns)
        } catch {
          return false
        }
        emitTarget = GifExportPolicy.advanceGifEmitTarget(
          emitTargetHns: emitTarget, keptFrameTsHns: tsHns)
        keptCount += 1
        if let onProgress {
          let progress = min(max(pts.seconds / durationSeconds, 0), 1)
          DispatchQueue.main.async { onProgress(progress) }
        }
        return true
      }

      if !ok {
        reader.cancelReading()
        encoder.cancel()
        return failure("Failed to encode a GIF frame.")
      }
    }

    if reader.status == .failed {
      encoder.cancel()
      return failure(reader.error?.localizedDescription ?? "Reading the rendered video failed.")
    }

    do {
      let wrote = try encoder.finalize()
      guard wrote, keptCount > 0 else {
        return failure("The GIF export produced no frames.")
      }
    } catch {
      encoder.cancel()
      return failure("Finalizing the GIF failed: \(error.localizedDescription)")
    }

    if let onProgress { DispatchQueue.main.async { onProgress(1.0) } }
    return .success(outputURL)
  }

  private func orientedSize(_ track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }

  /// CVPixelBuffer -> downscaled `CGImage` at `size` (aspect already baked into
  /// `size` by the policy). Skips scaling when the source already fits.
  ///
  /// The decode is the subtle part. The source is the exporter's own MOV, so
  /// its pixels carry `ColorTransferFunctions.exportTransferGamma` and the file
  /// is tagged BT.709. A GIF has no transfer tag — viewers read its palette as
  /// sRGB — so handing those values straight through published them about 11
  /// code values dark in the midtones, against an editor that showed sRGB.
  /// `decodeFromExport` puts them back in the space the GIF will be read in.
  private func makeDownscaledCGImage(from pixelBuffer: CVPixelBuffer, to size: CGSize) -> CGImage? {
    var image = ColorTransferFunctions.decodeFromExport(
      VideoColorPipeline.sourceImage(pixelBuffer: pixelBuffer)
    )
    let sourceExtent = image.extent
    guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }
    if size.width < sourceExtent.width || size.height < sourceExtent.height {
      image = image.transformed(
        by: CGAffineTransform(
          scaleX: size.width / sourceExtent.width,
          y: size.height / sourceExtent.height))
    }
    // Crop to the exact policy size so the emitted frame's pixel dimensions are
    // deterministic (the transform's extent can land a sub-pixel short).
    return ciContext.createCGImage(
      image,
      from: CGRect(origin: .zero, size: size),
      format: .RGBA8,
      colorSpace: VideoColorPipeline.workingColorSpace
    )
  }
}
