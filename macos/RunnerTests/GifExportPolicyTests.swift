import CoreGraphics
import XCTest

@testable import Clingfy

/// Pins the pure GIF sampling/timing/sizing policy. Mirrors the Windows
/// `gif_export_policy_test.cpp` vectors value-for-value (cross-platform parity),
/// plus the two macOS-additive behaviors: the long-edge render cap and the
/// drift-free `DelayAccumulator`. Pure / deterministic — no GPU, no encoder.
final class GifExportPolicyTests: XCTestCase {

  // MARK: - frameIntervalHns

  func testFrameIntervalMatchesTargetFps() {
    XCTAssertEqual(GifExportPolicy.frameIntervalHns(), 10_000_000 / 15)
    XCTAssertGreaterThan(GifExportPolicy.frameIntervalHns(), 0)
  }

  // MARK: - isGifDestination

  func testIsGifDestinationMatchesGifExtensionCaseInsensitively() {
    XCTAssertTrue(GifExportPolicy.isGifDestination("clip.gif"))
    XCTAssertTrue(GifExportPolicy.isGifDestination("/Users/me/Movies/My Clip.GIF"))
    XCTAssertTrue(GifExportPolicy.isGifDestination("/tmp/out.Gif"))
    XCTAssertTrue(GifExportPolicy.isGifDestination(".gif"))
  }

  func testIsGifDestinationRejectsNonGif() {
    XCTAssertFalse(GifExportPolicy.isGifDestination("clip.mov"))
    XCTAssertFalse(GifExportPolicy.isGifDestination("clip.mp4"))
    XCTAssertFalse(GifExportPolicy.isGifDestination("clip"))
    XCTAssertFalse(GifExportPolicy.isGifDestination(""))
    XCTAssertFalse(GifExportPolicy.isGifDestination("gif"))  // no dot
    XCTAssertFalse(GifExportPolicy.isGifDestination("clip.gif.mov"))  // not the final ext
  }

  // MARK: - shouldKeepGifFrame / advanceGifEmitTarget

  func testFirstFrameIsAlwaysKept() {
    XCTAssertTrue(
      GifExportPolicy.shouldKeepGifFrame(
        frameTsHns: 0, emitTargetHns: GifExportPolicy.emitTargetStart))
    XCTAssertTrue(
      GifExportPolicy.shouldKeepGifFrame(
        frameTsHns: 123_456, emitTargetHns: GifExportPolicy.emitTargetStart))
  }

  func testAdvanceAnchorsGridToTheKeptFrameThenStepsOneInterval() {
    let interval = GifExportPolicy.frameIntervalHns()
    // From the start sentinel, the next target snaps to one interval past frame 0.
    let t0 = GifExportPolicy.advanceGifEmitTarget(
      emitTargetHns: GifExportPolicy.emitTargetStart, keptFrameTsHns: 0)
    XCTAssertEqual(t0, interval)
    // A normal advance steps exactly one interval along the grid.
    XCTAssertEqual(
      GifExportPolicy.advanceGifEmitTarget(emitTargetHns: t0, keptFrameTsHns: interval),
      2 * interval)
    // A long source gap resyncs forward instead of leaving the target behind.
    let jump = 100 * interval
    XCTAssertEqual(
      GifExportPolicy.advanceGifEmitTarget(emitTargetHns: t0, keptFrameTsHns: jump),
      jump + interval)
  }

  func testKeepsOnlyOncePerIntervalAfterTheFirst() {
    let interval = GifExportPolicy.frameIntervalHns()
    let target = GifExportPolicy.advanceGifEmitTarget(
      emitTargetHns: GifExportPolicy.emitTargetStart, keptFrameTsHns: 0)
    XCTAssertEqual(target, interval)
    XCTAssertFalse(
      GifExportPolicy.shouldKeepGifFrame(frameTsHns: interval - 1, emitTargetHns: target))
    XCTAssertTrue(
      GifExportPolicy.shouldKeepGifFrame(frameTsHns: interval, emitTargetHns: target))
  }

  func testDecimates30FpsToEveryOtherFrame() {
    // A 30 fps source (33'333 HNS/frame) becomes ~15 fps walking the grid gate.
    let frameDur: Int64 = 10_000_000 / 30
    var target = GifExportPolicy.emitTargetStart
    var kept = 0
    for i in 0..<8 {
      let ts = Int64(i) * frameDur
      if GifExportPolicy.shouldKeepGifFrame(frameTsHns: ts, emitTargetHns: target) {
        kept += 1
        target = GifExportPolicy.advanceGifEmitTarget(emitTargetHns: target, keptFrameTsHns: ts)
      }
    }
    // 8 source frames at 30 fps -> 4 kept (frames 0,2,4,6).
    XCTAssertEqual(kept, 4)
  }

  func testJitteredCleanDivisorSourceStaysNearTargetRate() {
    // Real decoder timestamps jitter around exact frame multiples. The
    // grid-based target keeps the count at ~half a 30 fps source, where a
    // last-kept-timestamp gate degraded to every third frame under the same
    // jitter. Fixed deterministic pattern in +/-12 HNS (no RNG).
    let frameDur: Int64 = 10_000_000 / 30
    let jitter: [Int64] = [0, 9, -7, 11, -12, 5, -3, 8]
    var target = GifExportPolicy.emitTargetStart
    var kept = 0
    for i in 0..<8 {
      let ts = Int64(i) * frameDur + jitter[i]
      if GifExportPolicy.shouldKeepGifFrame(frameTsHns: ts, emitTargetHns: target) {
        kept += 1
        target = GifExportPolicy.advanceGifEmitTarget(emitTargetHns: target, keptFrameTsHns: ts)
      }
    }
    XCTAssertGreaterThanOrEqual(kept, 4)
    XCTAssertLessThanOrEqual(kept, 5)
  }

  // MARK: - delayCentiseconds (stateless parity port)

  func testDelayIsRoundedCentisecondsOfTheGap() {
    // 0.10 s gap -> 10 cs.
    XCTAssertEqual(GifExportPolicy.delayCentiseconds(prevTsHns: 0, curTsHns: 1_000_000), 10)
    // One 15 fps interval (~0.0667 s) -> round(6.67) = 7 cs.
    XCTAssertEqual(
      GifExportPolicy.delayCentiseconds(
        prevTsHns: 0, curTsHns: GifExportPolicy.frameIntervalHns()),
      7)
    // 0.50 s gap -> 50 cs.
    XCTAssertEqual(
      GifExportPolicy.delayCentiseconds(prevTsHns: 1_000_000, curTsHns: 6_000_000), 50)
  }

  func testDelayClampsUpToTheMinimumFloor() {
    // A tiny gap (1 ms = 0.1 cs) clamps up to the 2 cs floor most viewers honor.
    XCTAssertEqual(
      GifExportPolicy.delayCentiseconds(prevTsHns: 0, curTsHns: 10_000),
      GifExportPolicy.minDelayCentiseconds)
    // A zero / negative gap also clamps to the floor (defensive).
    XCTAssertEqual(
      GifExportPolicy.delayCentiseconds(prevTsHns: 500, curTsHns: 500),
      GifExportPolicy.minDelayCentiseconds)
    XCTAssertEqual(
      GifExportPolicy.delayCentiseconds(prevTsHns: 500, curTsHns: 100),
      GifExportPolicy.minDelayCentiseconds)
  }

  func testDelayClampsDownToThe16BitCeiling() {
    // A 700 s gap (70'000 cs) must clamp to the 16-bit GIF max (0xFFFF).
    XCTAssertEqual(
      GifExportPolicy.delayCentiseconds(prevTsHns: 0, curTsHns: 700 * 10_000_000), 0xFFFF)
  }

  // MARK: - DelayAccumulator (drift-free, macOS-additive)

  func testDelayAccumulatorKillsUniform15FpsDrift() {
    // A uniform 15 fps stream: each gap is one frame interval. The stateless
    // round stamps every frame at 7 cs -> 6 frames = 42 cs (+5% slow). The
    // accumulator carries the residual so delays alternate, summing to 40 cs
    // (== the true elapsed centiseconds) instead.
    let interval = GifExportPolicy.frameIntervalHns()
    var acc = GifExportPolicy.DelayAccumulator()
    var delays: [UInt16] = []
    for _ in 0..<6 { delays.append(acc.next(gapHns: interval)) }

    XCTAssertEqual(delays, [7, 6, 7, 7, 6, 7])
    let total = delays.reduce(0) { $0 + Int($1) }
    XCTAssertEqual(total, 40)  // true elapsed: 6 * 666'666 HNS = 40.0 cs
    // The naive per-gap round would have over-stamped.
    XCTAssertLessThan(total, 6 * Int(GifExportPolicy.defaultDelayCentiseconds))  // 42
  }

  func testDelayAccumulatorClampsTinyAndZeroGapsToTheFloor() {
    var acc = GifExportPolicy.DelayAccumulator()
    // 0.1 cs gap -> floor.
    XCTAssertEqual(acc.next(gapHns: 10_000), GifExportPolicy.minDelayCentiseconds)
    // A follow-up zero gap still floors (and doesn't run the clock backwards).
    XCTAssertEqual(acc.next(gapHns: 0), GifExportPolicy.minDelayCentiseconds)
  }

  // MARK: - renderSize (long-edge cap, macOS-additive)

  func testRenderSizeLeavesWithinCapCanvasUnchanged() {
    XCTAssertEqual(
      GifExportPolicy.renderSize(canvasSize: CGSize(width: 960, height: 540)),
      CGSize(width: 960, height: 540))
    // Exactly at the cap is not downscaled (strict greater-than).
    XCTAssertEqual(
      GifExportPolicy.renderSize(canvasSize: CGSize(width: 1080, height: 1080)),
      CGSize(width: 1080, height: 1080))
  }

  func testRenderSizeDownscales4KToTheCapPreservingAspect() {
    // Landscape 4K: the long edge is the width (3840) -> capped to 1080, so the
    // height scales to 2160 * (1080/3840) = 607.5 -> 608.
    XCTAssertEqual(
      GifExportPolicy.renderSize(canvasSize: CGSize(width: 3840, height: 2160)),
      CGSize(width: 1080, height: 608))
    // Portrait: the long edge is the height (1920) -> capped to 1080, width
    // scales to 1080 * (1080/1920) = 607.5 -> 608.
    XCTAssertEqual(
      GifExportPolicy.renderSize(canvasSize: CGSize(width: 1080, height: 1920)),
      CGSize(width: 608, height: 1080))
  }

  func testRenderSizeHonorsCustomMaxLongEdge() {
    XCTAssertEqual(
      GifExportPolicy.renderSize(canvasSize: CGSize(width: 1920, height: 1080), maxLongEdge: 480),
      CGSize(width: 480, height: 270))
  }

  func testRenderSizeGuardsDegenerateMaxLongEdge() {
    XCTAssertEqual(
      GifExportPolicy.renderSize(canvasSize: CGSize(width: 1920, height: 1080), maxLongEdge: 0),
      CGSize(width: 1920, height: 1080))
  }

  // MARK: - Size presets (Small / Medium / Large)

  func testSizePresetCapsMatchTheContract() {
    // Mirror of the Flutter GifSizePreset.longEdgePx values — keep in sync.
    XCTAssertEqual(GifExportPolicy.smallMaxLongEdge, 480)
    XCTAssertEqual(GifExportPolicy.mediumMaxLongEdge, 720)
    XCTAssertEqual(GifExportPolicy.largeMaxLongEdge, 1080)
    // Large is the default so an omitted preset renders exactly as before.
    XCTAssertEqual(GifExportPolicy.largeMaxLongEdge, GifExportPolicy.defaultMaxLongEdge)
  }

  func testMaxLongEdgeResolvesEachSizePreset() {
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: "small"), 480)
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: "medium"), 720)
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: "large"), 1080)
  }

  func testMaxLongEdgeIsCaseInsensitiveAndTrimmed() {
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: "SMALL"), 480)
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: "  Medium "), 720)
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: "Large\n"), 1080)
  }

  func testMaxLongEdgeFallsBackToLargeForUnknownOrNil() {
    // Older payloads (nil), empty, or a future/corrupt value all render at the
    // shipped 1080 cap — byte-for-byte the pre-control behavior.
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: nil), 1080)
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: ""), 1080)
    XCTAssertEqual(GifExportPolicy.maxLongEdge(forSizePreset: "gigantic"), 1080)
  }

  func testEachSizePresetDownscalesA1080LandscapeCanvas() {
    // A 1080p 16:9 canvas through each preset's resolved cap. Small/Medium
    // shrink the long edge; Large leaves the already-fitting canvas unchanged.
    let canvas = CGSize(width: 1920, height: 1080)
    XCTAssertEqual(
      GifExportPolicy.renderSize(
        canvasSize: canvas, maxLongEdge: GifExportPolicy.maxLongEdge(forSizePreset: "small")),
      CGSize(width: 480, height: 270))
    XCTAssertEqual(
      GifExportPolicy.renderSize(
        canvasSize: canvas, maxLongEdge: GifExportPolicy.maxLongEdge(forSizePreset: "medium")),
      CGSize(width: 720, height: 405))
    XCTAssertEqual(
      GifExportPolicy.renderSize(
        canvasSize: canvas, maxLongEdge: GifExportPolicy.maxLongEdge(forSizePreset: "large")),
      CGSize(width: 1080, height: 608))
  }

  // MARK: - intermediateRenderSize (what a GIF export's frames really are)

  /// `ExportEngine` renders a GIF at this size, and `resolveExportSize` reports
  /// it to Flutter so caption bitmaps are laid out for the frames they will
  /// land on. One function, two callers: when they disagreed, a caption
  /// rasterised for the uncapped canvas was composited about 1.8x too large,
  /// because the caption renderer only shrinks a bitmap WIDER than the frame.
  func testIntermediateRenderSizeCapsAndEvensTheCanvas() {
    // 1920x1080 at the Large cap: the long edge caps to 1080 and 607.5 rounds
    // to 608, which is already even.
    XCTAssertEqual(
      GifExportPolicy.intermediateRenderSize(canvasSize: CGSize(width: 1920, height: 1080)),
      CGSize(width: 1080, height: 608))
    // 3840x2160 lands on the same frame — the resolution preset is NOT what a
    // GIF renders at, which is the whole reason Flutter has to ask.
    XCTAssertEqual(
      GifExportPolicy.intermediateRenderSize(canvasSize: CGSize(width: 3840, height: 2160)),
      CGSize(width: 1080, height: 608))
  }

  func testIntermediateRenderSizeRoundsOddDimensionsUpToEven() {
    // The H.264 intermediate the GIF is transcoded from wants even dimensions.
    // 1920x1080 at the Medium cap: 720 x 405 -> 405 is odd.
    XCTAssertEqual(
      GifExportPolicy.intermediateRenderSize(
        canvasSize: CGSize(width: 1920, height: 1080),
        maxLongEdge: GifExportPolicy.maxLongEdge(forSizePreset: "medium")),
      CGSize(width: 720, height: 406))
  }

  func testIntermediateRenderSizeLeavesAnAlreadyFittingEvenCanvasAlone() {
    XCTAssertEqual(
      GifExportPolicy.intermediateRenderSize(canvasSize: CGSize(width: 960, height: 540)),
      CGSize(width: 960, height: 540))
  }

  func testIntermediateRenderSizeShrinksTheFrameCaptionsAreDrawnFor() {
    // The defect, stated as a ratio: at the Small preset a 1080p canvas becomes
    // a 480-wide frame, so a bitmap laid out for 1920 covers 4x the width it
    // was meant to. Anything that reports the uncapped canvas here brings that
    // back.
    let canvas = CGSize(width: 1920, height: 1080)
    let rendered = GifExportPolicy.intermediateRenderSize(
      canvasSize: canvas,
      maxLongEdge: GifExportPolicy.maxLongEdge(forSizePreset: "small"))
    XCTAssertLessThan(rendered.width, canvas.width)
    XCTAssertEqual(rendered, CGSize(width: 480, height: 270))
  }
}
