import CoreGraphics
import Foundation

/// Pure animated-GIF sampling / timing / sizing policy for the macOS export
/// path — no ImageIO, no AVFoundation — so it can be pinned by
/// `GifExportPolicyTests` without a GPU or encoder, mirroring how
/// `ExportPrep` / `ExportFormatInfo` keep their pure logic testable.
///
/// This is the macOS port of Windows'
/// `windows/runner/Capture/Export/gif_export_policy.{h,cpp}`. The decimation /
/// timing rules are ported **value-for-value** for cross-platform parity (see
/// `docs/decisions/macos-gif-export.md`). Two behaviors are additive on top of
/// the Windows contract and intentionally diverge from the line-for-line port
/// (a Windows follow-up will adopt them):
///
/// - `renderSize(canvasSize:maxLongEdge:)` — caps the GIF's long edge. A GIF
///   carries a full color table per frame and LZW-packs raw indices, so a 4K
///   canvas is a guaranteed multi-GB failure; the canvas is downscaled before
///   encode. Windows currently has no cap.
/// - `DelayAccumulator` — a drift-free per-frame delay generator. The stateless
///   `delayCentiseconds(prevTsHns:curTsHns:)` (the parity port) rounds each gap
///   independently, which stamps a uniform 15 fps stream +5% slow (every
///   ~0.0667 s gap rounds up to 7 cs). The accumulator carries the fractional
///   centisecond residual so cumulative playback time tracks wall-clock.
///
/// Why decimate: the pipeline walks decoded frames down toward `targetFps`
/// (a 30 fps source keeps every other frame → 15 fps; 60 fps keeps every
/// fourth), stamping each kept frame with the real gap to the next kept frame
/// (GIF delay units are centiseconds) so playback still tracks wall-clock time.
enum GifExportPolicy {
  // MARK: - Constants (ported from gif_export_policy.h)

  /// Target output frame rate for GIF. 15 fps is the smoothness/size sweet spot
  /// for screen recordings and divides cleanly from common 30/60 fps sources.
  static let targetFps: UInt32 = 15

  /// GIF delay is expressed in centiseconds (1/100 s). Most viewers silently
  /// clamp a sub-2 cs delay up to 10 cs, so never emit one below this floor.
  static let minDelayCentiseconds: UInt16 = 2

  /// Delay stamped on the final frame, which has no "next frame" to measure a
  /// gap against. round(100 / 15) = 7 cs (~14.3 fps), matching steady state.
  static let defaultDelayCentiseconds: UInt16 = 7

  /// Decimation uses a running emit TARGET on an ideal grid rather than tracking
  /// the last kept frame's actual timestamp. Seed the target with this sentinel
  /// (so the very first decoded frame is always kept). Anchoring the grid (vs.
  /// following the actual timestamp) keeps the output near `targetFps` even when
  /// real decoder timestamps jitter around the slot boundary.
  static let emitTargetStart: Int64 = .min

  /// Default long-edge cap (px) for the encoded GIF. Additive vs. Windows.
  /// Equals `large`'s cap — an omitted/unknown size preset renders exactly as
  /// before this control existed.
  static let defaultMaxLongEdge: CGFloat = 1080

  /// GIF size presets → long-edge cap (px). The wire values
  /// (`"small"`/`"medium"`/`"large"`) mirror the Flutter `GifSizePreset` enum
  /// and its `longEdgePx`; keep the two in sync. fps stays `targetFps` (15)
  /// across every preset — dimension is the file-size lever, and a per-preset
  /// fps would diverge from the Windows parity contract. Additive vs. Windows.
  static let smallMaxLongEdge: CGFloat = 480
  static let mediumMaxLongEdge: CGFloat = 720
  static let largeMaxLongEdge: CGFloat = 1080

  /// Resolve a GIF size-preset wire value to its long-edge cap. Unknown, empty,
  /// or `nil` (older Flutter payloads that predate the control) falls back to
  /// `defaultMaxLongEdge` (== `large`), so those exports are byte-for-byte
  /// unchanged. Matching is case-insensitive and whitespace-trimmed to mirror
  /// the Dart `gifSizePresetFromWire` parser.
  static func maxLongEdge(forSizePreset raw: String?) -> CGFloat {
    switch raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
    case "small": return smallMaxLongEdge
    case "medium": return mediumMaxLongEdge
    case "large": return largeMaxLongEdge
    default: return defaultMaxLongEdge
    }
  }

  private static let hnsPerSecond: Int64 = 10_000_000
  private static let hnsPerCentisecond: Int64 = 100_000  // 1/100 s in 100 ns units
  private static let delayCeilingCentiseconds: Int64 = 0xFFFF  // 16-bit GIF delay field

  // MARK: - Timing grid (ported value-for-value)

  /// HNS (100 ns) between kept frames at the target rate. 10'000'000 / fps.
  /// `targetFps` is a positive constant, so no divide-by-zero guard needed.
  static func frameIntervalHns() -> Int64 {
    hnsPerSecond / Int64(targetFps)
  }

  /// True when `path` names a `.gif` output (case-insensitive suffix). The
  /// pipeline keys the GIF encoder fork off the resolved destination extension.
  /// Matches the Windows semantics: the dot is required (`"gif"` → false) and
  /// `.gif` must be the final extension (`"clip.gif.mov"` → false).
  static func isGifDestination(_ path: String) -> Bool {
    path.lowercased().hasSuffix(".gif")
  }

  /// Keep `frameTsHns` once it has reached the running emit target. The start
  /// sentinel (`emitTargetStart`) makes any first frame pass.
  static func shouldKeepGifFrame(frameTsHns: Int64, emitTargetHns: Int64) -> Bool {
    frameTsHns >= emitTargetHns
  }

  /// Advance the emit target one interval along the ideal grid after keeping a
  /// frame. Snaps forward (`keptFrameTs + interval`) when the grid would
  /// otherwise lag behind the kept frame — i.e. from the start sentinel or after
  /// a long source gap.
  static func advanceGifEmitTarget(emitTargetHns: Int64, keptFrameTsHns: Int64) -> Int64 {
    let interval = frameIntervalHns()
    var next = emitTargetHns &+ interval
    if next <= keptFrameTsHns {
      next = keptFrameTsHns + interval
    }
    return next
  }

  // MARK: - Per-frame delay

  /// Stateless per-frame GIF delay (centiseconds) for the gap between two kept
  /// frames' timestamps. Rounded to the nearest centisecond, clamped up to
  /// `minDelayCentiseconds` (a non-positive gap clamps to the floor too) and
  /// down to the 16-bit field maximum. This is the parity port of Windows'
  /// `GifDelayCentiseconds`; prefer `DelayAccumulator` for drift-free output.
  static func delayCentiseconds(prevTsHns: Int64, curTsHns: Int64) -> UInt16 {
    let gap = curTsHns - prevTsHns
    return clampDelayCentiseconds(roundToCentiseconds(gap))
  }

  /// Round a positive HNS gap to the nearest centisecond. A non-positive gap
  /// returns 0 (which the clamp then lifts to the floor).
  private static func roundToCentiseconds(_ gapHns: Int64) -> Int64 {
    guard gapHns > 0 else { return 0 }
    return (gapHns + hnsPerCentisecond / 2) / hnsPerCentisecond
  }

  /// Clamp a raw centisecond count into the emit range `[floor, 0xFFFF]`.
  private static func clampDelayCentiseconds(_ cs: Int64) -> UInt16 {
    let floored = max(cs, Int64(minDelayCentiseconds))
    let capped = min(floored, delayCeilingCentiseconds)
    return UInt16(capped)
  }

  /// Drift-free per-frame delay generator. Fed the real HNS gap between each
  /// pair of consecutive kept frames, it carries the fractional-centisecond
  /// residual so the stamped cumulative time tracks wall-clock instead of
  /// accruing the +5% error a per-gap round would. For a uniform 15 fps stream
  /// the emitted delays alternate (7, 6, 7, 7, 6, …) averaging 6.667 cs.
  ///
  /// The floor/ceiling clamps still apply per frame; when the floor lifts a
  /// tiny gap it advances the stamped clock (acting as a rate limiter), exactly
  /// as the stateless version would.
  struct DelayAccumulator {
    private var trueElapsedHns: Int64 = 0
    private var stampedCentiseconds: Int64 = 0

    init() {}

    /// Delay (centiseconds) to stamp on the frame that opens `gapHns`.
    mutating func next(gapHns: Int64) -> UInt16 {
      if gapHns > 0 { trueElapsedHns &+= gapHns }
      let targetCs = (trueElapsedHns + hnsPerCentisecond / 2) / hnsPerCentisecond
      let raw = targetCs - stampedCentiseconds
      let delay = clampDelayCentiseconds(raw)
      stampedCentiseconds += Int64(delay)
      return delay
    }
  }

  // MARK: - Sizing (additive vs. Windows)

  /// The GIF's encoded pixel size: the canvas downscaled so its long edge is at
  /// most `maxLongEdge`, aspect preserved, rounded to whole pixels (min 1).
  /// Returns the canvas unchanged when it already fits (or is degenerate).
  static func renderSize(canvasSize: CGSize, maxLongEdge: CGFloat = defaultMaxLongEdge) -> CGSize {
    let longEdge = max(canvasSize.width, canvasSize.height)
    guard maxLongEdge > 0, longEdge > maxLongEdge else {
      return canvasSize
    }
    let scale = maxLongEdge / longEdge
    let width = max(1, (canvasSize.width * scale).rounded())
    let height = max(1, (canvasSize.height * scale).rounded())
    return CGSize(width: width, height: height)
  }
}
