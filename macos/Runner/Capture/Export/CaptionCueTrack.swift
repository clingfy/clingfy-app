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

  /// One frame the final-export colour validator can compare, expressed in
  /// BOTH timebases because the two things it compares do not share one.
  struct ValidationSample: Equatable {
    /// Position in the SOURCE-timed reference composition. "Cut at the writer"
    /// means the composition keeps source time; only the written file is
    /// compacted onto the edited timeline.
    let referenceMs: Int
    /// The same moment in the EDITED-timed exported file.
    let finalMs: Int
  }

  /// A frame carrying no burned-in caption, or `nil` when there is none — which
  /// includes the wall-to-wall-speech case, and which the caller must treat as
  /// "do not run this comparison" rather than "sample anywhere".
  ///
  /// This exists for the final-export colour validator. That validator compares
  /// one sampled frame of the finished file against a reference render built
  /// from the `AVVideoComposition`, and the composition never sees captions:
  /// they are composited in the writer loop, after the grade. So a sampled
  /// frame that happens to carry a caption charges the pill's pixels to the
  /// colour budget — and the default caption is 60%-opaque black across most of
  /// the frame width, which over bright content is a large fraction of a
  /// threshold whose whole job is catching transfer errors worth ~0.05.
  ///
  /// Returns both timebases because handing one number to both sides compares
  /// two different moments the instant the recording has a cut, and a reorder
  /// makes them unrelated. Content mismatch then reads as colour drift, and the
  /// validator deletes the file.
  ///
  /// Cues are sanitized exactly as the render path sanitizes them, so a cue the
  /// renderer would reject cannot make this treat a painted moment as a gap,
  /// and everything is clamped to the real source duration so a cue with times
  /// past the end of the recording cannot nominate a frame that does not exist.
  /// - Parameter frameDurationMs: how long one output frame lasts. A gap is
  ///   only usable if it is at least TWO frames wide, because the validator
  ///   samples a *frame*, not a millisecond: the frame shown at time `t` is the
  ///   last one whose presentation stamp is `<= t`, so a gap narrower than that
  ///   nominates an instant whose displayed frame still belongs to the cue
  ///   before it. At two frames the midpoint is more than one frame from each
  ///   edge, so the frame it lands on is strictly inside the gap. Defaults to 1
  ///   (millisecond precision) only so tests can reason without a frame rate.
  static func captionFreeSample(
    cues: [Cue],
    keptRanges: [ClipKeptRange],
    sourceDurationMs: Int,
    frameDurationMs: Int = 1
  ) -> ValidationSample? {
    guard !cues.isEmpty, sourceDurationMs > 0 else { return nil }
    let minimumUsableWidthMs = max(2 * max(frameDurationMs, 1), 2)

    // Same sorting and overlap rejection the renderer applies, so the cue set
    // reasoned about here is the cue set that actually paints.
    let painted = CaptionCueTrack(cues: cues).cues
      .compactMap { cue -> (start: Int, end: Int)? in
        let start = min(max(cue.startMs, 0), sourceDurationMs)
        let end = min(max(cue.endMs, 0), sourceDurationMs)
        return end > start ? (start, end) : nil
      }
    guard !painted.isEmpty else { return nil }

    var gaps: [(start: Int, end: Int)] = []
    var uncovered = 0
    for cue in painted {
      if cue.start - uncovered >= minimumUsableWidthMs {
        gaps.append((uncovered, cue.start))
      }
      uncovered = max(uncovered, cue.end)
    }
    if sourceDurationMs - uncovered >= minimumUsableWidthMs {
      gaps.append((uncovered, sourceDurationMs))
    }
    guard !gaps.isEmpty else { return nil }

    let ranges = keptRanges.compactMap { range -> ClipKeptRange? in
      let low = min(max(range.sourceInMs, 0), sourceDurationMs)
      let high = min(max(range.sourceOutMs, 0), sourceDurationMs)
      return high > low ? ClipKeptRange(sourceInMs: low, sourceOutMs: high) : nil
    }
    // An empty `keptRanges` means "no cuts, everything plays". Ranges that all
    // clamp away mean something is wrong with the edit, and treating that as
    // "no cuts" would map identity onto a timeline that does not exist.
    if !keptRanges.isEmpty, ranges.isEmpty { return nil }

    let editedDurationMs = ranges.isEmpty
      ? sourceDurationMs
      : ClipPlaybackPlanner.editedDurationMs(ranges: ranges)
    guard editedDurationMs > 0 else { return nil }
    let preferredEditedMs = editedDurationMs / 2

    var best: (sample: ValidationSample, distance: Int)?
    for gap in gaps {
      // A gap only helps if it survives the cut, so intersect it with the kept
      // ranges before mapping. With no cuts the gap maps through unchanged.
      let sourceCandidates: [Int] = ranges.isEmpty
        ? [(gap.start + gap.end) / 2]
        : ranges.compactMap { range in
          let low = max(gap.start, range.sourceInMs)
          let high = min(gap.end, range.sourceOutMs)
          // The surviving piece has to clear the same two-frame bar: a cut can
          // leave a sliver of an otherwise wide gap.
          return high - low >= minimumUsableWidthMs ? (low + high) / 2 : nil
        }
      for sourceMs in sourceCandidates {
        guard
          let editedMs = ClipPlaybackPlanner.editedMsForKeptSourceMs(
            sourceMs, ranges: ranges)
        else { continue }
        let distance = abs(editedMs - preferredEditedMs)
        if best == nil || distance < best!.distance {
          best = (ValidationSample(referenceMs: sourceMs, finalMs: editedMs), distance)
        }
      }
    }
    return best?.sample
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
