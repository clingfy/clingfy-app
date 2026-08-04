import Foundation

/// The export-side index of caption cues, plus the forward cursor the render
/// loop uses to find the active cue for a frame.
///
/// ```
///   SOURCE TIME ────────────────────────────────────────────────▶
///   cues      [ 0 ][ 1 ]      [ 2 ][ 3 ]              [ 4 ]
///   cursor     ^                                                  advances only
///                   ^                                             forward, O(1)
///                             ^                                   amortised
///
///   REORDER EXPORT (LetterboxExporter `rangeSequenced`):
///   one reader per kept range, read in TIMELINE order, so source time
///   JUMPS BACKWARD at every reader swap:
///
///     range B (source 30-40s) ──▶ range A (source 0-10s) ──▶ range C (50-60s)
///                                 ^^^^ cursor is parked at cue 3 and can never
///                                      walk back to cue 0 without a reset
///
///   `reset()` MUST be called at every reader swap. Without it captions
///   silently vanish for every range after the first — no error, no log, just
///   missing text in the exported file.
/// ```
///
/// Cues are stored in **source** time, matching `ZoomSegment`, because the
/// composition stays in source time and only the writer's PTS is remapped
/// (see `LetterboxExporter` "cut at the writer"). The render loop therefore
/// looks up by `sampleTime`, never by `outputPresentationTime`.
///
/// The cue list is required to be sorted by `startMs` and **non-overlapping**.
/// That is guaranteed upstream: mic and system transcripts are merged into one
/// resolved list at merge time, so this type never has to track a *set* of
/// simultaneously active cues.
struct CaptionCueTrack {

  /// One cue: a time span in source milliseconds and the bitmap that renders it.
  struct Cue: Equatable {
    let id: String
    let startMs: Int
    let endMs: Int
    /// File name (not a path) of the pre-rasterized RGBA bitmap for this cue,
    /// relative to the track's bitmap directory. Rasterization happens in
    /// Flutter at export resolution; native only composites.
    let bitmapName: String

    var isValid: Bool { endMs > startMs && !bitmapName.isEmpty }
  }

  private let cues: [Cue]
  private var cursor: Int = 0

  /// Cues that were dropped at construction because they were malformed or out
  /// of order. Non-empty means the Flutter side sent something unexpected;
  /// worth logging once at the call site rather than failing the export.
  let rejectedCueIds: [String]

  /// Builds a track from an arbitrary cue list. The input is sorted and
  /// sanitised here so the cursor's forward-only contract holds no matter what
  /// arrives over the bridge:
  ///
  /// - cues with `endMs <= startMs` or an empty bitmap name are rejected
  /// - remaining cues are sorted by `startMs`
  /// - a cue overlapping its predecessor is rejected rather than silently
  ///   truncated, because an overlap means the upstream merge failed and
  ///   guessing here would hide that
  init(cues: [Cue]) {
    var rejected: [String] = []
    let sorted = cues.filter { cue in
      guard cue.isValid else {
        rejected.append(cue.id)
        return false
      }
      return true
    }.sorted { lhs, rhs in
      lhs.startMs == rhs.startMs ? lhs.endMs < rhs.endMs : lhs.startMs < rhs.startMs
    }

    var kept: [Cue] = []
    kept.reserveCapacity(sorted.count)
    for cue in sorted {
      if let last = kept.last, cue.startMs < last.endMs {
        rejected.append(cue.id)
        continue
      }
      kept.append(cue)
    }

    self.cues = kept
    self.rejectedCueIds = rejected
  }

  var isEmpty: Bool { cues.isEmpty }
  var count: Int { cues.count }

  /// Rewinds the cursor. Call this whenever source time can move backwards —
  /// i.e. at every reader swap on the reorder export path, and when starting a
  /// fresh pass over the same track.
  mutating func reset() {
    cursor = 0
  }

  /// The cue covering `sourceMs`, or `nil` in a gap between cues.
  ///
  /// Forward-only: the cursor advances past cues that have ended and never
  /// walks back, so a full pass is O(cues) total rather than O(cues) per frame.
  /// A backward jump in `sourceMs` without a preceding `reset()` will return
  /// `nil` rather than a wrong cue — the cursor cannot rewind itself, so it
  /// reports "no caption" instead of a caption from the wrong moment.
  mutating func activeCue(atSourceMs sourceMs: Int) -> Cue? {
    while cursor < cues.count, cues[cursor].endMs <= sourceMs {
      cursor += 1
    }
    guard cursor < cues.count else { return nil }
    let candidate = cues[cursor]
    return candidate.startMs <= sourceMs ? candidate : nil
  }

  /// Non-mutating lookup for tests and for callers that cannot hold the track
  /// as `var`. O(log n); the render loop should use `activeCue(atSourceMs:)`.
  func cueForBinarySearch(atSourceMs sourceMs: Int) -> Cue? {
    var low = 0
    var high = cues.count - 1
    while low <= high {
      let mid = (low + high) / 2
      let cue = cues[mid]
      if sourceMs < cue.startMs {
        high = mid - 1
      } else if sourceMs >= cue.endMs {
        low = mid + 1
      } else {
        return cue
      }
    }
    return nil
  }
}

extension CaptionCueTrack.Cue {
  /// Parses one cue from the Flutter export payload. Returns `nil` on any
  /// missing or malformed field so a bad cue is dropped rather than crashing
  /// an export the user has already waited on.
  static func fromFlutter(_ raw: [String: Any]) -> CaptionCueTrack.Cue? {
    guard
      let id = raw["id"] as? String,
      let startMs = (raw["startMs"] as? NSNumber)?.intValue,
      let endMs = (raw["endMs"] as? NSNumber)?.intValue,
      let bitmapName = raw["bitmapName"] as? String
    else {
      return nil
    }
    return CaptionCueTrack.Cue(
      id: id, startMs: startMs, endMs: endMs, bitmapName: bitmapName)
  }

  static func listFromFlutter(_ raw: [[String: Any]]?) -> [CaptionCueTrack.Cue] {
    guard let raw else { return [] }
    return raw.compactMap { CaptionCueTrack.Cue.fromFlutter($0) }
  }
}
