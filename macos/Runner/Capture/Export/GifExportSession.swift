import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Turns composited frames into an animated GIF, one at a time: decimate to
/// `GifExportPolicy.targetFps`, undo the export transfer, downscale to the GIF
/// size if needed, and feed `GifEncoder`.
///
/// The one place a frame becomes a GIF frame. GIF exports render in a single
/// pass: `LetterboxExporter` hands each composited frame here straight from its
/// writer loop, after the same `renderComposedExportFrame` every video export
/// goes through, instead of writing a temp MOV. `GifExportSession` feeds it
/// from a finished video. Both therefore decimate, decode and encode the same
/// way. Not thread-safe: drive it from one queue.
final class GifFrameSink {
  struct SinkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  let gifSize: CGSize
  private let encoder: GifEncoder
  /// Must be the pipeline's context, not a bare `CIContext`. Core Image
  /// defaults to a LINEAR working space, and
  /// `ColorTransferFunctions.decodeFromExport` — like every kernel in that
  /// file — assumes it is handed gamma-encoded sRGB samples.
  /// `VideoColorPipeline.makeCIContext()` is what makes that true.
  private let ciContext = VideoColorPipeline.makeCIContext()
  private var emitTarget = GifExportPolicy.emitTargetStart
  private var lastTimestampHns: Int64?
  private(set) var keptCount = 0

  init(outputURL: URL, gifSize: CGSize) throws {
    self.gifSize = gifSize
    encoder = try GifEncoder(url: outputURL)
  }

  /// A presentation time in the 100 ns units the GIF policy uses.
  static func timestampHns(_ time: CMTime) -> Int64 {
    Int64((time.seconds * 10_000_000).rounded())
  }

  /// Whether the frame at `time` is kept by the decimation. Asking does not
  /// advance it; `append` does. Lets a caller skip composing dropped frames.
  func shouldKeep(_ time: CMTime) -> Bool {
    GifExportPolicy.shouldKeepGifFrame(
      frameTsHns: Self.timestampHns(time), emitTargetHns: emitTarget)
  }

  /// Encodes the frame in `pixelBuffer`, which carries the export transfer
  /// (`renderComposedExportFrame`'s output, or a decoded export video).
  /// Callers check `shouldKeep` first.
  func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws {
    let tsHns = Self.timestampHns(time)
    // A video writer refuses a timestamp that does not move forward; the GIF
    // encoder would quietly stamp it 2 cs. Refuse it the same way.
    if let lastTimestampHns, tsHns <= lastTimestampHns {
      throw SinkError(message: "A GIF frame arrived out of order.")
    }
    guard let cgImage = makeCGImage(from: pixelBuffer) else {
      throw SinkError(message: "Failed to prepare a GIF frame.")
    }
    try encoder.append(cgImage, timestampHns: tsHns)
    emitTarget = GifExportPolicy.advanceGifEmitTarget(
      emitTargetHns: emitTarget, keptFrameTsHns: tsHns)
    lastTimestampHns = tsHns
    keptCount += 1
  }

  /// Writes the GIF. Fails if no frame was kept.
  func finish() throws {
    let wrote: Bool
    do {
      wrote = try encoder.finalize()
    } catch {
      encoder.cancel()
      throw SinkError(message: "Finalizing the GIF failed: \(error.localizedDescription)")
    }
    guard wrote, keptCount > 0 else {
      throw SinkError(message: "The GIF export produced no frames.")
    }
  }

  /// Abandons the GIF and removes the partial file.
  func cancel() {
    encoder.cancel()
  }

  /// CVPixelBuffer -> `CGImage` at `gifSize`. Skips scaling when the frame
  /// already fits, which a single-pass export always does.
  ///
  /// The decode is the subtle part. The frame carries
  /// `ColorTransferFunctions.exportTransferGamma` — it went through
  /// `renderComposedExportFrame`, like every exported video frame. A GIF has no
  /// transfer tag — viewers read its palette as sRGB — so handing those values
  /// straight through published them about 11 code values dark in the
  /// midtones, against an editor that showed sRGB. `decodeFromExport` puts them
  /// back in the space the GIF will be read in.
  private func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    var image = ColorTransferFunctions.decodeFromExport(
      VideoColorPipeline.sourceImage(pixelBuffer: pixelBuffer)
    )
    let sourceExtent = image.extent
    guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }
    if gifSize.width < sourceExtent.width || gifSize.height < sourceExtent.height {
      image = image.transformed(
        by: CGAffineTransform(
          scaleX: gifSize.width / sourceExtent.width,
          y: gifSize.height / sourceExtent.height))
    }
    // Crop to the exact policy size so the emitted frame's pixel dimensions are
    // deterministic (the transform's extent can land a sub-pixel short).
    return ciContext.createCGImage(
      image,
      from: CGRect(origin: .zero, size: gifSize),
      format: .RGBA8,
      colorSpace: VideoColorPipeline.workingColorSpace
    )
  }
}

/// Converts a finished, fully-composited video into an animated GIF through
/// `GifFrameSink`. Exports no longer go this way (they render GIF in one pass);
/// it remains for converting an existing video, and as the reference the
/// single-pass path is tested against.
final class GifExportSession {
  struct GifExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private let workQueue = DispatchQueue(label: "com.clingfy.gif-export", qos: .userInitiated)
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

    let sink: GifFrameSink
    do {
      sink = try GifFrameSink(outputURL: outputURL, gifSize: gifSize)
    } catch {
      reader.cancelReading()
      return failure("Could not create the GIF file: \(error.localizedDescription)")
    }

    readLoop: while reader.status == .reading {
      if isCancelled {
        reader.cancelReading()
        sink.cancel()
        return failure("Export cancelled")
      }
      guard let sample = output.copyNextSampleBuffer() else { break }

      let ok: Bool = autoreleasepool {
        defer { CMSampleBufferInvalidate(sample) }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Decimate to the target fps on the ideal grid.
        guard sink.shouldKeep(pts), let buffer = CMSampleBufferGetImageBuffer(sample) else {
          return true  // dropped by decimation, or a frame with no image buffer
        }
        do {
          try sink.append(buffer, at: pts)
        } catch {
          return false
        }
        if let onProgress {
          let progress = min(max(pts.seconds / durationSeconds, 0), 1)
          DispatchQueue.main.async { onProgress(progress) }
        }
        return true
      }

      if !ok {
        reader.cancelReading()
        sink.cancel()
        return failure("Failed to encode a GIF frame.")
      }
    }

    if reader.status == .failed {
      sink.cancel()
      return failure(reader.error?.localizedDescription ?? "Reading the rendered video failed.")
    }

    do {
      try sink.finish()
    } catch {
      return .failure(error)
    }

    if let onProgress { DispatchQueue.main.async { onProgress(1.0) } }
    return .success(outputURL)
  }

  private func orientedSize(_ track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }
}
