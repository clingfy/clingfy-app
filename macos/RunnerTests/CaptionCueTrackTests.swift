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

  // MARK: - Caption-free sampling for the colour validator
  //
  // The final-export validator compares one sampled frame against a render of
  // the composition, and the composition never carries captions — they are
  // composited later, in the writer loop. Sampling a captioned frame therefore
  // charges the caption's own pixels to a colour budget sized for transfer
  // errors, which can fail and DELETE a correct export.

  func testPicksTheGapNearestTheMidpointOnAnUncutRecording() {
    // Cues at 0-1s and 8-10s in a 10s recording. Midpoint is 5s, inside the
    // 1-8s gap, so the answer should land there. With no cuts the two
    // timebases coincide.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("a", 0, 1000), cue("b", 8000, 10000)],
      keptRanges: [],
      sourceDurationMs: 10000)
    XCTAssertEqual(chosen?.referenceMs, 4500, "midpoint of the 1000-8000 gap")
    XCTAssertEqual(chosen?.finalMs, 4500, "no cut, so source and edited agree")
  }

  func testReturnsNilWhenCuesLeaveNoGap() {
    // Wall-to-wall speech. There is no caption-free frame to find, and saying
    // so is what lets the caller fall back and log rather than pick a lie.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("a", 0, 5000), cue("b", 5000, 10000)],
      keptRanges: [],
      sourceDurationMs: 10000)
    XCTAssertNil(chosen, "the caller must skip the comparison, not sample anyway")
  }

  func testReturnsNilWithNoCuesSoTheCallerKeepsItsOwnMidpoint() {
    XCTAssertNil(
      CaptionCueTrack.captionFreeSample(
        cues: [], keptRanges: [], sourceDurationMs: 10000),
      "no captions means nothing to avoid")
  }

  func testMapsTheGapThroughACutOntoTheEditedTimeline() {
    // Keep 0-2s and 6-10s of a 10s source: a 6s edited timeline. The only
    // caption-free source moment is 1000-2000 (the 2000-6000 stretch was cut
    // away), which sits at 1000-2000 on the edited timeline too.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("a", 0, 1000), cue("b", 6000, 10000)],
      keptRanges: [
        ClipKeptRange(sourceInMs: 0, sourceOutMs: 2000),
        ClipKeptRange(sourceInMs: 6000, sourceOutMs: 10000),
      ],
      sourceDurationMs: 10000)
    XCTAssertEqual(chosen?.referenceMs, 1500, "midpoint of the surviving 1000-2000 gap")
    XCTAssertEqual(chosen?.finalMs, 1500, "first range starts at edited zero")
  }

  func testIgnoresAGapThatTheCutRemovedEntirely() {
    // The only gap in source (2000-6000) is exactly what the cut dropped, so
    // every frame that survives carries a caption.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("a", 0, 2000), cue("b", 6000, 10000)],
      keptRanges: [
        ClipKeptRange(sourceInMs: 0, sourceOutMs: 2000),
        ClipKeptRange(sourceInMs: 6000, sourceOutMs: 10000),
      ],
      sourceDurationMs: 10000)
    XCTAssertNil(chosen, "the gap did not survive the cut")
  }

  func testMapsThroughAReorderRatherThanAssumingSourceOrder() {
    // Ranges listed out of source order: 6-10s plays first, then 0-2s. A gap at
    // source 1000-2000 therefore lands at edited 5000-6000, not 1000-2000.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("a", 0, 1000), cue("b", 6000, 10000)],
      keptRanges: [
        ClipKeptRange(sourceInMs: 6000, sourceOutMs: 10000),
        ClipKeptRange(sourceInMs: 0, sourceOutMs: 2000),
      ],
      sourceDurationMs: 10000)
    XCTAssertEqual(chosen?.referenceMs, 1500, "the gap is at 1500 in the SOURCE")
    XCTAssertEqual(
      chosen?.finalMs, 5500,
      "4000ms of range one plays first, then 1500 into range two")
  }

  func testACueRunningPastTheEndOfTheRecordingCannotNominateAFrame() {
    // ASR can emit a cue whose end overshoots the recording. Reasoning over raw
    // cue times would find a "gap" between two out-of-range cues and hand back
    // a frame that does not exist in either asset; clamping to the real
    // duration is what stops that landing back on a captioned frame.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("a", 0, 9000), cue("b", 20000, 30000)],
      keptRanges: [],
      sourceDurationMs: 10000)
    XCTAssertEqual(
      chosen?.referenceMs, 9500,
      "the only real gap is 9000-10000, inside the recording")
    XCTAssertNil(
      CaptionCueTrack.captionFreeSample(
        cues: [cue("a", 0, 10000), cue("b", 20000, 30000)],
        keptRanges: [],
        sourceDurationMs: 10000),
      "a cue past the end cannot manufacture a gap")
  }

  func testCuesTheRendererWouldRejectDoNotOpenAFakeGap() {
    // An overlapping cue is rejected by the renderer, so it never paints — but
    // it must not be reasoned about here either, or its span could be treated
    // as covered and hide the real gap, or vice versa. Same sanitisation both
    // sides is the invariant.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [
        cue("a", 0, 4000),
        cue("overlaps", 3000, 9000),  // rejected: starts before `a` ends
        cue("b", 9000, 10000),
      ],
      keptRanges: [],
      sourceDurationMs: 10000)
    XCTAssertEqual(
      chosen?.referenceMs, 6500,
      "4000-9000 is genuinely uncaptioned once the overlap is rejected")
  }

  func testAZeroDurationRecordingIsRefusedRatherThanDividedBy() {
    XCTAssertNil(
      CaptionCueTrack.captionFreeSample(
        cues: [cue("a", 0, 1000)], keptRanges: [], sourceDurationMs: 0))
  }

  /// The exporter derives `assetDurationMs` by TRUNCATING, and the Flutter side
  /// clamps the last cue to that same truncated value. If the validator's call
  /// site rounds instead, `sourceDurationMs` is one larger for about a third of
  /// durations and this 1 ms tail appears — uncaptioned, at the very end of a
  /// recording that is captioned to its last frame. Nominating it is how a
  /// wall-to-wall export gets sampled on a captioned frame and deleted.
  func testAOneMillisecondTailIsTooNarrowToNominate() {
    XCTAssertNil(
      CaptionCueTrack.captionFreeSample(
        cues: [cue("a", 0, 10000)],
        keptRanges: [],
        sourceDurationMs: 10001,
        frameDurationMs: 33),
      "a 1 ms tail is far narrower than a frame")
    XCTAssertNil(
      CaptionCueTrack.captionFreeSample(
        cues: [cue("a", 0, 10000)],
        keptRanges: [],
        sourceDurationMs: 10001),
      "and still too narrow even at millisecond precision")
  }

  /// The validator samples a FRAME, not a millisecond: the frame on screen at
  /// time t is the last one stamped at or before t. A gap narrower than two
  /// frames therefore names an instant whose displayed frame still belongs to
  /// the cue before it, and the export gets deleted for the caption it was
  /// supposed to avoid.
  func testAGapNarrowerThanTwoFramesIsRejectedEvenWhenItSitsAtTheMidpoint() {
    // Continuous speech from 0 to 45 s with one 20 ms hole at the exact centre,
    // then 15 s of real silence. Ranked by nearness to the middle alone, the
    // 20 ms hole would win — it is 180 ms from the midpoint, the tail is 22.5 s.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("intro", 0, 29000), cue("a", 29000, 29810), cue("b", 29830, 45000)],
      keptRanges: [],
      sourceDurationMs: 60000,
      frameDurationMs: 33)
    XCTAssertEqual(
      chosen?.referenceMs, 52500,
      "the wide tail gap wins; the 20 ms hole is under two frames")
  }

  func testAGapOfExactlyTwoFramesIsUsableAndLandsClearOfBothCues() {
    // Two frames wide is the smallest safe gap: the midpoint sits a full frame
    // from each edge, so whichever frame is displayed there is inside the gap.
    let chosen = CaptionCueTrack.captionFreeSample(
      cues: [cue("a", 0, 1000), cue("b", 1066, 10000)],
      keptRanges: [],
      sourceDurationMs: 10000,
      frameDurationMs: 33)
    XCTAssertEqual(chosen?.referenceMs, 1033)
    let track = CaptionCueTrack(cues: [cue("a", 0, 1000), cue("b", 1066, 10000)])
    XCTAssertNil(
      track.cueForBinarySearch(atSourceMs: 1033),
      "the nominated instant must not be inside a cue")
    XCTAssertNil(
      track.cueForBinarySearch(atSourceMs: 1033 - 33),
      "nor must the frame that would actually be displayed there")
  }

  func testRangesThatSurviveNothingAreRefused() {
    // Every kept range clamps away to nothing (they sit past the recording), so
    // there is no edited timeline to place a sample on.
    XCTAssertNil(
      CaptionCueTrack.captionFreeSample(
        cues: [cue("a", 0, 1000)],
        keptRanges: [ClipKeptRange(sourceInMs: 50000, sourceOutMs: 60000)],
        sourceDurationMs: 10000))
  }
}
