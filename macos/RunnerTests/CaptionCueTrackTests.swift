import XCTest

@testable import Clingfy

/// Covers the forward cursor the caption burn-in loop depends on.
///
/// The load-bearing test here is `testReorderExportWithoutResetLosesEveryLaterRange`
/// paired with `testReorderExportWithResetKeepsEveryRange`: together they are the
/// mutation check for the reset contract. If someone deletes the `reset()` call at
/// the reader swap, the first of those two still passes (it asserts the broken
/// behaviour) and the second fails loudly. Without that pair the regression is
/// silent — captions simply stop appearing partway through a reordered export.
final class CaptionCueTrackTests: XCTestCase {

  private func cue(_ id: String, _ startMs: Int, _ endMs: Int) -> CaptionCueTrack.Cue {
    CaptionCueTrack.Cue(id: id, startMs: startMs, endMs: endMs, bitmapName: "\(id).png")
  }

  /// 0-1s, 2-3s, 5-6s. Deliberately gappy so "no caption here" is exercised.
  private func sampleTrack() -> CaptionCueTrack {
    CaptionCueTrack(cues: [cue("a", 0, 1000), cue("b", 2000, 3000), cue("c", 5000, 6000)])
  }

  // MARK: - Forward scanning

  func testFindsCueAtStartMiddleAndLastMillisecond() {
    var track = sampleTrack()
    XCTAssertEqual(track.activeCue(atSourceMs: 0)?.id, "a", "start is inclusive")
    XCTAssertEqual(track.activeCue(atSourceMs: 500)?.id, "a")
    XCTAssertEqual(track.activeCue(atSourceMs: 999)?.id, "a", "last ms before end is covered")
  }

  func testEndIsExclusiveSoAdjacentCuesDoNotDoubleRender() {
    var track = CaptionCueTrack(cues: [cue("a", 0, 1000), cue("b", 1000, 2000)])
    XCTAssertEqual(track.activeCue(atSourceMs: 1000)?.id, "b", "end is exclusive")
  }

  func testReturnsNilInAGapBetweenCues() {
    var track = sampleTrack()
    XCTAssertNil(track.activeCue(atSourceMs: 1500), "gap between a and b")
    XCTAssertEqual(track.activeCue(atSourceMs: 2500)?.id, "b", "cursor still usable after a gap")
  }

  func testReturnsNilAfterTheFinalCue() {
    var track = sampleTrack()
    XCTAssertEqual(track.activeCue(atSourceMs: 5500)?.id, "c")
    XCTAssertNil(track.activeCue(atSourceMs: 6000), "end is exclusive")
    XCTAssertNil(track.activeCue(atSourceMs: 99_000))
  }

  func testMonotonicWalkOverEveryFrameVisitsEachCue() {
    var track = sampleTrack()
    var seen: [String] = []
    // 60fps over 7s, the access pattern the writer loop actually produces.
    for frame in 0..<420 {
      let ms = Int((Double(frame) / 60.0) * 1000.0)
      if let id = track.activeCue(atSourceMs: ms)?.id, seen.last != id {
        seen.append(id)
      }
    }
    XCTAssertEqual(seen, ["a", "b", "c"])
  }

  // MARK: - The reset contract (reorder export)

  /// Documents the BROKEN behaviour so the pair below is a real mutation check.
  /// Source time jumps backward at a reader swap; a cursor that is never reset
  /// cannot walk back, so everything after the first range renders no captions.
  func testReorderExportWithoutResetLosesEveryLaterRange() {
    var track = sampleTrack()
    // Range 1 is source 5-6s (a later part of the recording, placed first).
    XCTAssertEqual(track.activeCue(atSourceMs: 5500)?.id, "c")
    // Reader swaps to range 2 = source 0-1s. No reset.
    XCTAssertNil(
      track.activeCue(atSourceMs: 500),
      "without reset the cursor is parked past cue a and reports no caption")
  }

  func testReorderExportWithResetKeepsEveryRange() {
    var track = sampleTrack()
    XCTAssertEqual(track.activeCue(atSourceMs: 5500)?.id, "c")

    track.reset()  // what LetterboxExporter must do at every reader swap
    XCTAssertEqual(
      track.activeCue(atSourceMs: 500)?.id, "a",
      "after reset the earlier range renders its captions again")

    track.reset()
    XCTAssertEqual(track.activeCue(atSourceMs: 2500)?.id, "b")
  }

  func testResetIsIdempotentAndSafeBeforeAnyLookup() {
    var track = sampleTrack()
    track.reset()
    track.reset()
    XCTAssertEqual(track.activeCue(atSourceMs: 0)?.id, "a")
  }

  // MARK: - Sanitising what arrives over the bridge

  func testUnsortedInputIsSorted() {
    var track = CaptionCueTrack(cues: [cue("c", 5000, 6000), cue("a", 0, 1000), cue("b", 2000, 3000)])
    XCTAssertEqual(track.activeCue(atSourceMs: 500)?.id, "a")
    XCTAssertEqual(track.activeCue(atSourceMs: 5500)?.id, "c")
  }

  func testZeroLengthAndInvertedCuesAreRejected() {
    let track = CaptionCueTrack(cues: [
      cue("ok", 0, 1000),
      cue("zero", 2000, 2000),
      cue("inverted", 5000, 4000),
    ])
    XCTAssertEqual(track.count, 1)
    XCTAssertEqual(Set(track.rejectedCueIds), ["zero", "inverted"])
  }

  func testCueWithNoBitmapIsRejected() {
    let track = CaptionCueTrack(cues: [
      CaptionCueTrack.Cue(id: "nobitmap", startMs: 0, endMs: 1000, bitmapName: "")
    ])
    XCTAssertTrue(track.isEmpty)
    XCTAssertEqual(track.rejectedCueIds, ["nobitmap"])
  }

  /// Overlap means the upstream mic/system merge failed. Rejecting is louder
  /// than truncating, and it protects the cursor's single-active-cue contract.
  func testOverlappingCueIsRejectedRatherThanTruncated() {
    let track = CaptionCueTrack(cues: [cue("a", 0, 2000), cue("overlaps", 1000, 3000)])
    XCTAssertEqual(track.count, 1)
    XCTAssertEqual(track.rejectedCueIds, ["overlaps"])
  }

  func testEmptyTrackNeverReturnsACue() {
    var track = CaptionCueTrack(cues: [])
    XCTAssertTrue(track.isEmpty)
    XCTAssertNil(track.activeCue(atSourceMs: 0))
    track.reset()
    XCTAssertNil(track.activeCue(atSourceMs: 1000))
  }

  // MARK: - Cursor and binary search must agree

  func testCursorAgreesWithBinarySearchAcrossTheWholeTimeline() {
    var track = sampleTrack()
    for ms in stride(from: 0, through: 7000, by: 17) {
      let viaCursor = track.activeCue(atSourceMs: ms)?.id
      let viaSearch = track.cueForBinarySearch(atSourceMs: ms)?.id
      XCTAssertEqual(viaCursor, viaSearch, "disagreement at \(ms)ms")
    }
  }

  // MARK: - Bridge parsing

  func testParsesAWellFormedCuePayload() {
    let parsed = CaptionCueTrack.Cue.fromFlutter([
      "id": "cue_7", "startMs": NSNumber(value: 1200), "endMs": NSNumber(value: 2400),
      "bitmapName": "cue_7.png",
    ])
    XCTAssertEqual(parsed?.id, "cue_7")
    XCTAssertEqual(parsed?.startMs, 1200)
    XCTAssertEqual(parsed?.endMs, 2400)
    XCTAssertEqual(parsed?.bitmapName, "cue_7.png")
  }

  func testMalformedCuesAreDroppedNotCrashed() {
    XCTAssertNil(CaptionCueTrack.Cue.fromFlutter(["id": "x", "startMs": NSNumber(value: 0)]))
    XCTAssertNil(CaptionCueTrack.Cue.fromFlutter([:]))
    XCTAssertNil(
      CaptionCueTrack.Cue.fromFlutter([
        "id": 42, "startMs": NSNumber(value: 0), "endMs": NSNumber(value: 1),
        "bitmapName": "a.png",
      ]), "non-string id")
  }

  func testListParsingSkipsBadEntriesAndKeepsGoodOnes() {
    let cues = CaptionCueTrack.Cue.listFromFlutter([
      ["id": "a", "startMs": NSNumber(value: 0), "endMs": NSNumber(value: 1000), "bitmapName": "a.png"],
      ["id": "broken"],
      ["id": "b", "startMs": NSNumber(value: 2000), "endMs": NSNumber(value: 3000), "bitmapName": "b.png"],
    ])
    XCTAssertEqual(cues.map(\.id), ["a", "b"])
  }
}
