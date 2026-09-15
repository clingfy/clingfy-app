import CoreGraphics
import Foundation

/// The cue track the LIVE PREVIEW draws from.
///
/// Deliberately separate from `CaptionCueTrack`, which the export uses, because
/// the two have opposite access patterns and opposite timebases:
///
/// * The export walks strictly forward through source time, so it can carry a
///   monotonic cursor and a cache of one bitmap.
/// * The preview is scrubbed, seeked, paused and replayed, so every lookup is
///   random access. A forward-only cursor here would leave the caption blank
///   for everything before wherever the user last was.
///
/// Times are EDITED (output) milliseconds — where the cue lands in the file the
/// export would produce — because the preview player's own clock is edited time
/// once a kept-range composition is playing.
struct CaptionPreviewTrack: Equatable {
  struct Cue: Equatable {
    let id: String
    /// Edited-timeline milliseconds. End is exclusive.
    let startMs: Int
    let endMs: Int
    /// File name only. Resolved against the manifest's directory so the two
    /// sides cannot disagree about where bitmaps live.
    let bitmapName: String

    static func fromFlutter(_ raw: [String: Any]) -> Cue? {
      guard
        let id = raw["id"] as? String,
        let startMs = (raw["startMs"] as? NSNumber)?.intValue,
        let endMs = (raw["endMs"] as? NSNumber)?.intValue,
        let bitmapName = raw["bitmapName"] as? String,
        endMs > startMs, startMs >= 0, !bitmapName.isEmpty
      else {
        return nil
      }
      return Cue(id: id, startMs: startMs, endMs: endMs, bitmapName: bitmapName)
    }
  }

  /// Sorted by start, with overlaps dropped.
  private(set) var cues: [Cue] = []

  /// Directory holding the bitmaps named by [cues].
  let bitmapDirectory: URL

  /// The canvas the bitmaps were rasterized against.
  ///
  /// Load-bearing rather than informational: the caption font scales with
  /// canvas height and the wrap width is a fraction of canvas width, so a
  /// bitmap built for another canvas is the wrong size and possibly the wrong
  /// line count. When this does not match the live composition target the
  /// caption is hidden rather than drawn at a size the export will not
  /// reproduce — a wrong preview is worse than no preview, because the whole
  /// point is judging how the caption looks.
  let canvasSize: CGSize

  init(cues: [Cue], bitmapDirectory: URL, canvasSize: CGSize) {
    self.bitmapDirectory = bitmapDirectory
    self.canvasSize = canvasSize

    var kept: [Cue] = []
    for cue in cues.sorted(by: { $0.startMs == $1.startMs ? $0.endMs < $1.endMs : $0.startMs < $1.startMs }
    ) {
      // Two cues visible at once would fight for the same screen position, so
      // the later one is dropped rather than stacked. Reflow already
      // guarantees non-overlap; this is the guard for a payload that does not.
      if let last = kept.last, cue.startMs < last.endMs { continue }
      kept.append(cue)
    }
    self.cues = kept
  }

  var isEmpty: Bool { cues.isEmpty }
  var count: Int { cues.count }

  /// The cue covering `editedMs`, or nil.
  ///
  /// Binary search, so scrubbing backwards costs the same as playing forwards.
  func activeCue(atEditedMs editedMs: Int) -> Cue? {
    var low = 0
    var high = cues.count - 1
    while low <= high {
      let mid = (low + high) / 2
      let cue = cues[mid]
      if editedMs < cue.startMs {
        high = mid - 1
      } else if editedMs >= cue.endMs {
        low = mid + 1
      } else {
        return cue
      }
    }
    return nil
  }

  func bitmapURL(for cue: Cue) -> URL {
    bitmapDirectory.appendingPathComponent(cue.bitmapName, isDirectory: false)
  }

  /// Parses the `previewSetCaptions` payload. Returns nil when captions should
  /// be off — an absent payload, no directory, or no usable cue.
  static func fromFlutter(_ args: [String: Any]?) -> CaptionPreviewTrack? {
    guard
      let args,
      let directory = args["bitmapDirectory"] as? String, !directory.isEmpty,
      let rawCues = args["cues"] as? [[String: Any]]
    else {
      return nil
    }
    let cues = rawCues.compactMap { Cue.fromFlutter($0) }
    if cues.isEmpty { return nil }

    let width = (args["canvasWidth"] as? NSNumber)?.doubleValue ?? 0
    let height = (args["canvasHeight"] as? NSNumber)?.doubleValue ?? 0
    guard width > 0, height > 0 else { return nil }

    return CaptionPreviewTrack(
      cues: cues,
      bitmapDirectory: URL(fileURLWithPath: directory),
      canvasSize: CGSize(width: width, height: height))
  }

  /// Whether these bitmaps may be drawn on a composition rendering at
  /// `targetSize`.
  ///
  /// Compared with a tolerance of one pixel per axis: both sides round the same
  /// `resolveTargetSize` result, and refusing to draw over a rounding artifact
  /// would blank the captions for no visible reason.
  func matches(targetSize: CGSize) -> Bool {
    abs(canvasSize.width - targetSize.width) <= 1
      && abs(canvasSize.height - targetSize.height) <= 1
  }
}
