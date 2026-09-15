import CoreGraphics
import CoreImage
import Foundation

/// Composites pre-rasterized caption bitmaps into export frames.
///
/// ## Why this does no text layout
///
/// Captions are rasterized in **Flutter**, at export resolution, into a temp
/// directory; this type only places the resulting bitmap. That split exists
/// because the app already shapes Arabic correctly through Flutter's text
/// engine with no bundled font, while this target has no CoreText usage at all.
/// Doing layout here would mean bundling a font, registering it with
/// `CTFontManager`, and asserting bidi and ligature behaviour — all of which the
/// Flutter path gets for free, and all of which Windows would need again in
/// DirectWrite.
///
/// ## Where this runs, and why the seat matters
///
/// ```
///   reader ──▶ composition output          (zoom, cursor, camera, mask already baked)
///                    │
///                    ├─ ColorGradeRenderer.apply       LetterboxExporter :2544
///                    │        the user's colour grade
///                    │
///                    ├─ CaptionOverlayRenderer.composite   ◀── HERE
///                    │        captions are NOT graded
///                    │
///                    └─ renderComposedExportFrame       LetterboxExporter :2547
///                             encodeForExport → 709 transfer
/// ```
///
/// Compositing **before** the grade (i.e. at the `AVVideoCompositionCoreAnimationTool`
/// seat in `CompositionBuilder`) would let a user who warms their video also tint
/// their captions, so a picked caption colour would not survive to the file. That
/// is the same defect class as #383/#391.
///
/// The seat is still **upstream of `encodeForExport`**, which is correct — captions
/// go through the same transfer as every other pixel — but it means any test
/// sampling the output must decode with `ColorTransferFunctions.exportTransferToSrgb`
/// before comparing against the authored colour.
final class CaptionOverlayRenderer {

  /// Fraction of the canvas height the caption sits above the bottom edge.
  ///
  /// Mirrors `CaptionStyle.bottomMarginFraction`'s default on the Dart side
  /// (`lib/core/timeline/model/edit_track.dart`). This constant is a stand-in
  /// until the full style is threaded across the bridge; when it is, the export
  /// should pass the user's value instead and this becomes the fallback for
  /// payloads that omit it.
  static let defaultBottomMarginFraction: CGFloat = 0.08

  /// Directory holding one bitmap per cue, written by Flutter before the export
  /// starts. Bitmaps are loaded lazily and one at a time.
  private let bitmapDirectory: URL

  /// The single decoded bitmap held in memory. The render loop walks cues
  /// forward via `CaptionCueTrack`'s monotonic cursor, so a cache of one is
  /// enough to avoid re-decoding a PNG for every frame of the same cue —
  /// at 60fps a three-second cue would otherwise decode 180 times.
  private var cachedCueId: String?
  private var cachedImage: CIImage?

  /// Cue ids whose bitmap could not be loaded. Non-empty means Flutter and
  /// native disagree about the directory contents; log once at the call site
  /// rather than failing an export the user has already waited on.
  private(set) var missingBitmapCueIds: [String] = []

  init(bitmapDirectory: URL) {
    self.bitmapDirectory = bitmapDirectory
  }

  /// Places `bitmapExtent` inside `renderBounds`: horizontally centred, and
  /// lifted off the bottom edge by `bottomMarginFraction` of the canvas height.
  ///
  /// Pure and separated from file loading so the geometry is testable without
  /// touching disk. Core Image's origin is bottom-left, so the margin is a
  /// direct `y` offset rather than something subtracted from the height.
  ///
  /// A bitmap wider than the canvas is scaled down to fit with its aspect ratio
  /// preserved. That should not happen — Flutter rasterizes at export
  /// resolution — but a silently cropped caption is a worse failure than a
  /// slightly small one.
  static func placement(
    bitmapExtent: CGRect,
    in renderBounds: CGRect,
    bottomMarginFraction: CGFloat
  ) -> CGRect {
    guard bitmapExtent.width > 0, bitmapExtent.height > 0,
      renderBounds.width > 0, renderBounds.height > 0
    else {
      return .zero
    }

    var width = bitmapExtent.width
    var height = bitmapExtent.height
    if width > renderBounds.width {
      let scale = renderBounds.width / width
      width *= scale
      height *= scale
    }

    let clampedFraction = min(max(bottomMarginFraction, 0), 1)
    let x = renderBounds.minX + ((renderBounds.width - width) / 2.0)
    let y = renderBounds.minY + (renderBounds.height * clampedFraction)

    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// Returns `image` with the cue's bitmap composited over it, or `image`
  /// unchanged when the bitmap is missing or unusable.
  ///
  /// Never throws and never returns nil: a caption problem must not fail an
  /// export that is otherwise fine.
  func composite(
    _ image: CIImage,
    cue: CaptionCueTrack.Cue,
    renderBounds: CGRect,
    bottomMarginFraction: CGFloat
  ) -> CIImage {
    guard let overlay = bitmap(for: cue) else { return image }

    let target = Self.placement(
      bitmapExtent: overlay.extent,
      in: renderBounds,
      bottomMarginFraction: bottomMarginFraction
    )
    guard target.width > 0, target.height > 0 else { return image }

    // Move the bitmap from its own origin to the target, scaling only if the
    // width had to be clamped above.
    let scale = target.width / overlay.extent.width
    let placed =
      overlay
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .transformed(
        by: CGAffineTransform(
          translationX: target.minX - (overlay.extent.minX * scale),
          y: target.minY - (overlay.extent.minY * scale)
        ))

    return placed.composited(over: image)
  }

  /// Loads and caches the cue's bitmap. Cache depth is one because the cursor
  /// only ever moves forward.
  private func bitmap(for cue: CaptionCueTrack.Cue) -> CIImage? {
    if cachedCueId == cue.id { return cachedImage }

    let url = bitmapDirectory.appendingPathComponent(cue.bitmapName)
    guard let loaded = CIImage(contentsOf: url) else {
      if !missingBitmapCueIds.contains(cue.id) {
        missingBitmapCueIds.append(cue.id)
      }
      // Cache the miss too, so a missing file is not re-stat'd every frame.
      cachedCueId = cue.id
      cachedImage = nil
      return nil
    }

    cachedCueId = cue.id
    cachedImage = loaded
    return loaded
  }

  /// Drops the cached bitmap. Call alongside `CaptionCueTrack.reset()` at a
  /// reader swap so the two stay in step.
  func reset() {
    cachedCueId = nil
    cachedImage = nil
  }
}
