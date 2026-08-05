import CoreGraphics
import XCTest

@testable import Clingfy

/// The cue track the live preview draws from.
///
/// Its two differences from the export's `CaptionCueTrack` are the whole point
/// and are what these pin: lookups are random access (the preview is scrubbed),
/// and times are EDITED rather than source.
final class CaptionPreviewTrackTests: XCTestCase {

  private func cue(
    _ id: String, _ startMs: Int, _ endMs: Int, bitmap: String = "a.png"
  ) -> CaptionPreviewTrack.Cue {
    CaptionPreviewTrack.Cue(id: id, startMs: startMs, endMs: endMs, bitmapName: bitmap)
  }

  private func track(
    _ cues: [CaptionPreviewTrack.Cue],
    canvas: CGSize = CGSize(width: 1920, height: 1080)
  ) -> CaptionPreviewTrack {
    CaptionPreviewTrack(
      cues: cues, bitmapDirectory: URL(fileURLWithPath: "/tmp/caps"), canvasSize: canvas)
  }

  // MARK: - Random access

  /// The export walks forward and can carry a cursor. The preview cannot: the
  /// user scrubs backwards constantly, and a forward-only cursor would leave
  /// every earlier caption blank once they had played past it.
  func testScrubbingBackwardsStillFindsEarlierCues() {
    let t = track([cue("a", 0, 1000), cue("b", 2000, 3000), cue("c", 4000, 5000)])

    XCTAssertEqual(t.activeCue(atEditedMs: 4500)?.id, "c")
    XCTAssertEqual(t.activeCue(atEditedMs: 500)?.id, "a", "a backwards seek must resolve")
    XCTAssertEqual(t.activeCue(atEditedMs: 2500)?.id, "b")
    XCTAssertEqual(t.activeCue(atEditedMs: 500)?.id, "a")
  }

  func testEveryMillisecondAgreesWithALinearScan() {
    let cues = (0..<40).map { cue("c\($0)", $0 * 250, $0 * 250 + 180) }
    let t = track(cues)

    for ms in stride(from: -50, through: 10_100, by: 7) {
      let expected = cues.first { ms >= $0.startMs && ms < $0.endMs }
      XCTAssertEqual(t.activeCue(atEditedMs: ms)?.id, expected?.id, "at \(ms)")
    }
  }

  func testGapsAndEndsReturnNothing() {
    let t = track([cue("a", 1000, 2000)])
    XCTAssertNil(t.activeCue(atEditedMs: 0))
    XCTAssertNil(t.activeCue(atEditedMs: 999))
    XCTAssertNil(t.activeCue(atEditedMs: 5000))
    XCTAssertNil(t.activeCue(atEditedMs: -1))
  }

  func testEndIsExclusiveSoAdjacentCuesDoNotBothMatch() {
    let t = track([cue("a", 0, 1000), cue("b", 1000, 2000)])
    XCTAssertEqual(t.activeCue(atEditedMs: 999)?.id, "a")
    XCTAssertEqual(t.activeCue(atEditedMs: 1000)?.id, "b")
  }

  func testEmptyTrackNeverReturnsACue() {
    XCTAssertNil(track([]).activeCue(atEditedMs: 0))
    XCTAssertTrue(track([]).isEmpty)
  }

  // MARK: - Sanitising

  func testUnsortedInputIsSorted() {
    let t = track([cue("c", 4000, 5000), cue("a", 0, 1000), cue("b", 2000, 3000)])
    XCTAssertEqual(t.cues.map(\.id), ["a", "b", "c"])
  }

  /// Two captions on screen at once would draw on top of each other in the same
  /// spot. Reflow already guarantees non-overlap; this is the guard for a
  /// payload that does not.
  func testOverlappingCuesAreDropped() {
    let t = track([cue("a", 0, 3000), cue("b", 1000, 4000)])
    XCTAssertEqual(t.cues.map(\.id), ["a"])
  }

  // MARK: - Payload parsing

  func testParsesAWellFormedPayload() {
    let parsed = CaptionPreviewTrack.fromFlutter([
      "bitmapDirectory": "/tmp/caps",
      "canvasWidth": NSNumber(value: 1920),
      "canvasHeight": NSNumber(value: 1080),
      "cues": [
        ["id": "c1", "startMs": NSNumber(value: 0), "endMs": NSNumber(value: 1500),
         "bitmapName": "abc.png"]
      ],
    ])
    XCTAssertEqual(parsed?.count, 1)
    XCTAssertEqual(parsed?.cues.first?.bitmapName, "abc.png")
    XCTAssertEqual(parsed?.canvasSize, CGSize(width: 1920, height: 1080))
  }

  /// Every one of these means "show no captions", which must be a clean nil
  /// rather than a half-built track.
  func testPayloadsThatMeanCaptionsOff() {
    XCTAssertNil(CaptionPreviewTrack.fromFlutter(nil))
    XCTAssertNil(CaptionPreviewTrack.fromFlutter([:]))
    XCTAssertNil(
      CaptionPreviewTrack.fromFlutter([
        "bitmapDirectory": "", "canvasWidth": NSNumber(value: 1920),
        "canvasHeight": NSNumber(value: 1080), "cues": [],
      ]))
    XCTAssertNil(
      CaptionPreviewTrack.fromFlutter([
        "bitmapDirectory": "/tmp/caps", "canvasWidth": NSNumber(value: 1920),
        "canvasHeight": NSNumber(value: 1080), "cues": [],
      ]))
  }

  func testAZeroCanvasIsRefused() {
    // Dividing placement by a zero canvas would put the caption nowhere; better
    // to show none than to draw at a degenerate size.
    XCTAssertNil(
      CaptionPreviewTrack.fromFlutter([
        "bitmapDirectory": "/tmp/caps",
        "canvasWidth": NSNumber(value: 0), "canvasHeight": NSNumber(value: 1080),
        "cues": [
          ["id": "c1", "startMs": NSNumber(value: 0), "endMs": NSNumber(value: 100),
           "bitmapName": "a.png"]
        ],
      ]))
  }

  func testMalformedCuesAreDroppedNotCrashed() {
    let parsed = CaptionPreviewTrack.fromFlutter([
      "bitmapDirectory": "/tmp/caps",
      "canvasWidth": NSNumber(value: 1920),
      "canvasHeight": NSNumber(value: 1080),
      "cues": [
        ["id": "good", "startMs": NSNumber(value: 0), "endMs": NSNumber(value: 100),
         "bitmapName": "a.png"],
        ["startMs": NSNumber(value: 200), "endMs": NSNumber(value: 300),
         "bitmapName": "b.png"],  // no id
        ["id": "noBitmap", "startMs": NSNumber(value: 400), "endMs": NSNumber(value: 500)],
        ["id": "inverted", "startMs": NSNumber(value: 900), "endMs": NSNumber(value: 800),
         "bitmapName": "c.png"],
        ["id": "empty", "startMs": NSNumber(value: 1000), "endMs": NSNumber(value: 1000),
         "bitmapName": "d.png"],
      ],
    ])
    XCTAssertEqual(parsed?.cues.map(\.id), ["good"])
  }

  // MARK: - Canvas match

  /// The caption font scales with canvas height and the wrap width is a
  /// fraction of canvas width, so a bitmap built for another canvas is the
  /// wrong size and sometimes the wrong number of lines. Showing nothing while
  /// a preset change is in flight beats showing a size the export will not
  /// reproduce — judging that size is the whole reason the preview exists.
  func testBitmapsBuiltForAnotherCanvasAreRefused() {
    let t = track([cue("a", 0, 1000)], canvas: CGSize(width: 1920, height: 1080))
    XCTAssertTrue(t.matches(targetSize: CGSize(width: 1920, height: 1080)))
    XCTAssertFalse(t.matches(targetSize: CGSize(width: 1080, height: 1920)))
    XCTAssertFalse(t.matches(targetSize: CGSize(width: 3840, height: 2160)))
  }

  /// Both sides round the same resolveTargetSize result, so blanking the
  /// captions over a one-pixel rounding artifact would be a bug of its own.
  func testASubPixelDifferenceStillMatches() {
    let t = track([cue("a", 0, 1000)], canvas: CGSize(width: 1920.4, height: 1080.2))
    XCTAssertTrue(t.matches(targetSize: CGSize(width: 1920, height: 1080)))
  }

  // MARK: - Timebase

  /// The preview's caption track is on the EDITED timeline; every other overlay
  /// in `sendTick` is keyed to SOURCE time and maps edited→source first. Feeding
  /// the caption lookup that mapped value — the natural mistake, since it is the
  /// variable every neighbouring line uses — puts captions at the wrong moment
  /// on any recording with a cut.
  ///
  /// This pins the consequence rather than the call: with 5s trimmed off the
  /// front, the two values pick different cues, so a regression is a wrong
  /// caption on screen and not merely a different number.
  func testEditedAndSourceTimePickDifferentCuesOnACutRecording() {
    // Kept range: source [5000, 20000) → edited [0, 15000).
    let ranges = [ClipKeptRange(sourceInMs: 5000, sourceOutMs: 20000)]
    let editedMs = 1000
    let sourceMs = ClipPlaybackPlanner.sourceMs(forEditedMs: editedMs, ranges: ranges)
    XCTAssertEqual(sourceMs, 6000, "5s of trimmed head")

    let t = track([
      cue("correct", 0, 2000, bitmap: "a.png"),
      cue("wrong", 6000, 8000, bitmap: "b.png"),
    ])

    XCTAssertEqual(
      t.activeCue(atEditedMs: editedMs)?.id, "correct",
      "the player's own time is what the track is keyed to")
    XCTAssertEqual(
      t.activeCue(atEditedMs: sourceMs)?.id, "wrong",
      "and the source mapping picks a different cue — that is the bug shape")
  }

  /// On an unedited recording the two timebases coincide, which is exactly why
  /// this class of mistake survives casual testing: it is invisible until a
  /// recording has a cut.
  func testTheTwoTimebasesAgreeWhenNothingWasCut() {
    let sourceMs = ClipPlaybackPlanner.sourceMs(forEditedMs: 1000, ranges: [])
    XCTAssertEqual(sourceMs, 1000)
  }

  // MARK: - Placement parity with the export

  /// The preview must place captions with the EXPORT's own function, against
  /// the same rect, or the user proof-reads a position the file will not have.
  ///
  /// The rect is the full CANVAS, never the letterboxed video rect. On a 9:16
  /// canvas from a 16:9 recording that is the difference between the caption
  /// sitting in the bottom bar (correct — where the export puts it) and tucked
  /// inside the bottom of the picture, hundreds of pixels higher.
  func testPreviewUsesTheSamePlacementAsTheExport() {
    let canvas = CGRect(x: 0, y: 0, width: 1080, height: 1920)
    let bitmap = CGRect(x: 0, y: 0, width: 800, height: 120)

    let placed = CaptionOverlayRenderer.placement(
      bitmapExtent: bitmap, in: canvas,
      bottomMarginFraction: CaptionOverlayRenderer.defaultBottomMarginFraction)

    XCTAssertEqual(placed.minY, 1920 * 0.08, accuracy: 0.001)
    XCTAssertEqual(placed.midX, 540, accuracy: 0.001)
    XCTAssertEqual(placed.size, bitmap.size)

    // The video rect on this canvas is 1080x607.5 centred vertically. Anchoring
    // there instead would be ~551 canvas pixels too high — 28% of the frame.
    let videoRect = CGRect(x: 0, y: 656.25, width: 1080, height: 607.5)
    let wrong = CaptionOverlayRenderer.placement(
      bitmapExtent: bitmap, in: videoRect,
      bottomMarginFraction: CaptionOverlayRenderer.defaultBottomMarginFraction)
    XCTAssertGreaterThan(wrong.minY - placed.minY, 500)
  }
}
