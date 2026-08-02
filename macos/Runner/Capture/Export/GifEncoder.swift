import CoreGraphics
import Foundation
import ImageIO

/// Streaming animated-GIF writer over ImageIO's `CGImageDestination`, the macOS
/// counterpart to Windows' WIC `gif_encoder`. Kept deliberately thin: it owns
/// the ImageIO destination, the infinite-loop flag, per-frame delay stamping,
/// and the opaque flatten — the frame *source* and decimation live in the GIF
/// export session (see `docs/decisions/macos-gif-export.md`).
///
/// Three behaviors are load-bearing (each pinned by `GifEncoderTests`):
///
/// - **Streaming, not buffered.** Frames are flattened + appended + released one
///   at a time via `CGImageDestinationCreateWithURL` (never `…WithData`), so RSS
///   stays flat regardless of clip length.
/// - **Lookahead delays.** A GIF frame's delay is the gap to the *next* frame,
///   so each appended frame is held one step; when the following frame arrives
///   the pending one is committed with the measured gap (via the drift-free
///   `GifExportPolicy.DelayAccumulator`). The final frame — which has no
///   successor — gets `GifExportPolicy.defaultDelayCentiseconds`.
/// - **Opaque flatten.** Every frame is drawn into a no-alpha context
///   (`.noneSkipFirst`) before ImageIO sees it, so ImageIO can never allocate a
///   transparent palette index (which would produce edge halos Windows
///   structurally can't). Both `GIFDelayTime` and `GIFUnclampedDelayTime` are
///   written so legacy and modern decoders keep the same cadence.
final class GifEncoder {
  enum GifEncoderError: Error {
    case destinationCreationFailed(URL)
    case flattenFailed
  }

  /// Raw GIF UTI. Used instead of `UTType.gif` so the encoder builds/runs on the
  /// full deployment range (predates the `UniformTypeIdentifiers` framework).
  private static let gifUTI = "com.compuserve.gif" as CFString

  private let url: URL
  private let destination: CGImageDestination
  private let backgroundColor: CGColor
  private var accumulator = GifExportPolicy.DelayAccumulator()

  private var pendingImage: CGImage?
  private var pendingTimestampHns: Int64 = 0
  private var appendedCount = 0
  private var finalized = false

  /// - Parameters:
  ///   - url: destination `.gif` path.
  ///   - frameCountHint: expected frame count (an ImageIO sizing hint only; more
  ///     or fewer frames may be appended).
  ///   - backgroundColor: color composited under any sub-1.0 alpha during the
  ///     opaque flatten. Defaults to opaque black.
  init(url: URL, frameCountHint: Int = 0, backgroundColor: CGColor? = nil) throws {
    self.url = url
    self.backgroundColor =
      backgroundColor
      ?? CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1])!
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, GifEncoder.gifUTI, max(frameCountHint, 0), nil)
    else {
      throw GifEncoderError.destinationCreationFailed(url)
    }
    self.destination = destination

    // Infinite loop (0). Set once on the destination before appending frames.
    let loopProperties: [CFString: Any] = [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ]
    CGImageDestinationSetProperties(destination, loopProperties as CFDictionary)
  }

  /// Queue `image` at `timestampHns`. The previously queued frame (if any) is
  /// committed here, stamped with the real gap between the two timestamps.
  func append(_ image: CGImage, timestampHns: Int64) throws {
    if let pending = pendingImage {
      let gap = timestampHns - pendingTimestampHns
      try commit(pending, delayCentiseconds: accumulator.next(gapHns: gap))
    }
    pendingImage = image
    pendingTimestampHns = timestampHns
  }

  /// Flush the last frame with the default delay and write the file.
  /// Returns `false` (writing nothing, removing any partial) when no frames were
  /// ever appended or ImageIO fails to finalize.
  @discardableResult
  func finalize() throws -> Bool {
    if let pending = pendingImage {
      try commit(pending, delayCentiseconds: GifExportPolicy.defaultDelayCentiseconds)
      pendingImage = nil
    }
    guard appendedCount > 0, CGImageDestinationFinalize(destination) else {
      removePartialFile()
      return false
    }
    finalized = true
    return true
  }

  /// Abandon the encode and delete any partial file. Safe to call after a
  /// successful `finalize()` (a no-op then).
  func cancel() {
    guard !finalized else { return }
    pendingImage = nil
    removePartialFile()
  }

  private func commit(_ image: CGImage, delayCentiseconds: UInt16) throws {
    guard let opaque = flattenedOpaque(image) else { throw GifEncoderError.flattenFailed }
    let seconds = Double(delayCentiseconds) / 100.0
    let frameProperties: [CFString: Any] = [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: seconds,
        kCGImagePropertyGIFUnclampedDelayTime: seconds,
      ]
    ]
    CGImageDestinationAddImage(destination, opaque, frameProperties as CFDictionary)
    appendedCount += 1
  }

  /// Draw `image` into a no-alpha RGB context so ImageIO never sees alpha. The
  /// background shows through any originally-transparent pixels (thin AA / round
  /// corners once the canvas is composited); the default opaque black mirrors
  /// Windows forcing an opaque clear color.
  private func flattenedOpaque(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    let bitmapInfo =
      CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard
      let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
    else {
      return nil
    }

    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(backgroundColor)
    context.fill(rect)
    context.draw(image, in: rect)
    return context.makeImage()
  }

  private func removePartialFile() {
    try? FileManager.default.removeItem(at: url)
  }
}
