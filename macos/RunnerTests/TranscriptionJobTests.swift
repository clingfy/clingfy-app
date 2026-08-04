import XCTest

@testable import Clingfy

/// Covers the engine-agnostic half of transcription: hallucination guards,
/// speaker-bleed dedup, overlap resolution, progress and cancellation.
///
/// All of it runs against a fake transcriber. That is the point of the
/// `CaptionTranscriber` seam — none of this logic should need a 600 MB model
/// download to be verified, and none of it should change when the engine does.
final class TranscriptionJobTests: XCTestCase {

  // MARK: - Fake engine

  private final class FakeTranscriber: CaptionTranscriber {
    var availability: TranscriberAvailability = .available
    /// Segments to return, keyed by last path component so a two-source job can
    /// hand back different transcripts per file.
    var byFile: [String: [TranscribedSegment]] = [:]
    var progressSteps: [Double] = [0.5, 1.0]
    private(set) var transcribedFiles: [String] = []
    private(set) var optionsUsed: [TranscriptionOptions] = []

    func transcribe(
      url: URL,
      options: TranscriptionOptions,
      progress: @escaping (Double) -> Void,
      isCancelled: @escaping () -> Bool
    ) throws -> [TranscribedSegment] {
      transcribedFiles.append(url.lastPathComponent)
      optionsUsed.append(options)
      for step in progressSteps {
        if isCancelled() { throw TranscriptionError.cancelled }
        progress(step)
      }
      if isCancelled() { throw TranscriptionError.cancelled }
      return byFile[url.lastPathComponent] ?? []
    }
  }

  private func seg(
    _ startMs: Int, _ endMs: Int, _ text: String, noSpeech: Double? = nil
  ) -> TranscribedSegment {
    TranscribedSegment(
      startMs: startMs, endMs: endMs, text: text, words: [],
      noSpeechProbability: noSpeech)
  }

  private func url(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/project.clingfyproj/capture/\(name)")
  }

  // MARK: - Hallucination guards

  /// The modal failure for a screen recorder: Whisper inventing text over
  /// silence, and pause handling pads gaps with explicit silence.
  func testDropsSegmentsTheEngineFlaggedAsProbablyNotSpeech() {
    let kept = TranscriptionJob.applyGuards(
      [
        seg(0, 2000, "Real speech here", noSpeech: 0.1),
        seg(3000, 5000, "Thank you.", noSpeech: 0.95),
      ], options: .default)
    XCTAssertEqual(kept.map(\.text), ["Real speech here"])
  }

  func testTheStrictProfileIsStricterThanTheDefault() {
    let segments = [seg(0, 2000, "Maybe speech", noSpeech: 0.5)]
    XCTAssertEqual(
      TranscriptionJob.applyGuards(segments, options: .default).count, 1,
      "0.5 is under the default 0.6 threshold")
    XCTAssertEqual(
      TranscriptionJob.applyGuards(segments, options: .strict).count, 0,
      "system audio is mostly music, so the prior is different")
  }

  func testDropsFlashCuesTooShortToRead() {
    let kept = TranscriptionJob.applyGuards(
      [seg(0, 120, "Blip"), seg(1000, 3000, "Readable")], options: .default)
    XCTAssertEqual(kept.map(\.text), ["Readable"])
  }

  func testDropsPunctuationOnlyFragments() {
    let kept = TranscriptionJob.applyGuards(
      [seg(0, 2000, "."), seg(3000, 5000, "  "), seg(6000, 8000, "Real")],
      options: .default)
    XCTAssertEqual(kept.map(\.text), ["Real"])
  }

  /// Whisper's second documented failure over music is a repetition loop.
  func testSuppressesImmediateRepeatsWithinTheWindow() {
    let kept = TranscriptionJob.applyGuards(
      [
        seg(0, 2000, "you know"),
        seg(2500, 4500, "You know"),
        seg(20000, 22000, "you know"),
      ], options: .default)
    XCTAssertEqual(
      kept.count, 2,
      "the near repeat is dropped; the one past the window is kept")
  }

  func testTrimsWhitespaceFromKeptText() {
    let kept = TranscriptionJob.applyGuards(
      [seg(0, 2000, "  padded  ")], options: .default)
    XCTAssertEqual(kept.first?.text, "padded")
  }

  // MARK: - Bleed dedup

  /// The rule that is the reverse of intuition. System audio is a clean digital
  /// tap; the mic hears it through the speakers. Measured on real recordings:
  /// r ≈ 0.9 correlation, mic ~30 dB down. So the SYSTEM copy survives.
  func testKeepsTheSystemCopyAndDropsTheBleedingMicCopy() {
    let merged = TranscriptionJob.merge(
      mic: [seg(1050, 3000, "welcome to the show")],
      system: [seg(1000, 3000, "welcome to the show")])
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged.first?.source, .system, "the clean digital tap wins")
  }

  func testBleedDedupToleratesSegmentationJitter() {
    // ~50 ms is the measured acoustic offset; Whisper moves boundaries far more.
    let merged = TranscriptionJob.merge(
      mic: [seg(1900, 4000, "the quick brown fox")],
      system: [seg(1000, 3000, "the quick brown fox")])
    XCTAssertEqual(merged.count, 1, "900ms apart is inside the tolerance")
  }

  func testDoesNotDedupWhenTheTextIsGenuinelyDifferent() {
    let merged = TranscriptionJob.merge(
      mic: [seg(1000, 2000, "completely different words")],
      system: [seg(1000, 2000, "welcome to the show")])
    XCTAssertEqual(merged.count, 1, "simultaneous, so merged into one cue")
    XCTAssertEqual(merged.first?.source, .mixed)
    XCTAssertTrue(merged.first!.text.contains("\n"), "two speakers, two lines")
  }

  func testDoesNotDedupTheSameWordsFarApartInTime() {
    let merged = TranscriptionJob.merge(
      mic: [seg(60000, 62000, "welcome to the show")],
      system: [seg(1000, 3000, "welcome to the show")])
    XCTAssertEqual(merged.count, 2, "a minute apart is a genuine repeat")
  }

  func testMicOnlyRecordingKeepsEverything() {
    let merged = TranscriptionJob.merge(
      mic: [seg(0, 2000, "one"), seg(3000, 5000, "two")], system: [])
    XCTAssertEqual(merged.map(\.text), ["one", "two"])
    XCTAssertTrue(merged.allSatisfy { $0.source == .mic })
  }

  // MARK: - Overlap resolution

  /// Non-overlap is a contract the export depends on: it lets the writer loop's
  /// cue cursor stay a forward scan rather than tracking a set of active cues.
  func testOutputIsAlwaysSortedAndNonOverlapping() {
    let merged = TranscriptionJob.merge(
      mic: [seg(0, 5000, "long mic line"), seg(9000, 11000, "later")],
      system: [seg(3000, 7000, "overlapping system line")])
    for (a, b) in zip(merged, merged.dropFirst()) {
      XCTAssertLessThanOrEqual(a.endMs, b.startMs, "cues must not overlap")
      XCTAssertLessThanOrEqual(a.startMs, b.startMs, "cues must be sorted")
    }
  }

  func testPartialOverlapPushesTheLaterStart() {
    let merged = TranscriptionJob.merge(
      mic: [seg(0, 3000, "first speaker talking")],
      system: [seg(2000, 6000, "second speaker replying")])
    XCTAssertEqual(merged.count, 2)
    XCTAssertEqual(merged[1].startMs, 3000, "pushed to the end of the first")
  }

  func testCueIdsAreUniqueAndOrdered() {
    let merged = TranscriptionJob.merge(
      mic: [seg(0, 1000, "a"), seg(2000, 3000, "b"), seg(4000, 5000, "c")],
      system: [])
    XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    XCTAssertEqual(merged.map(\.id), ["cue_0", "cue_1", "cue_2"])
  }

  // MARK: - Source selection

  func testTranscribesBothSourcesWhenBothExist() throws {
    let fake = FakeTranscriber()
    fake.byFile = [
      "mic.m4a": [seg(0, 2000, "from the mic")],
      "system.m4a": [seg(5000, 7000, "from the system")],
    ]
    let job = TranscriptionJob(transcriber: fake)
    let cues = try job.run(
      sources: .init(micURL: url("mic.m4a"), systemURL: url("system.m4a"), embeddedURL: nil),
      progress: { _ in }, isCancelled: { false })

    XCTAssertEqual(fake.transcribedFiles.sorted(), ["mic.m4a", "system.m4a"])
    XCTAssertEqual(cues.count, 2)
  }

  func testAppliesTheStrictProfileToSystemAudioOnly() throws {
    let fake = FakeTranscriber()
    let job = TranscriptionJob(transcriber: fake)
    _ = try job.run(
      sources: .init(micURL: url("mic.m4a"), systemURL: url("system.m4a"), embeddedURL: nil),
      progress: { _ in }, isCancelled: { false })
    XCTAssertEqual(fake.optionsUsed.count, 2)
    XCTAssertEqual(fake.optionsUsed[0].noSpeechThreshold, TranscriptionOptions.default.noSpeechThreshold)
    XCTAssertEqual(fake.optionsUsed[1].noSpeechThreshold, TranscriptionOptions.strict.noSpeechThreshold)
  }

  /// macOS 13-14 recordings have no sidecars at all, because SourceAudioRecorder
  /// is macOS 15+. Not an edge case — a whole supported slice of the install base.
  func testFallsBackToEmbeddedAudioWhenNoSidecarsExist() throws {
    let fake = FakeTranscriber()
    fake.byFile = ["screen.mov": [seg(0, 2000, "from the premix")]]
    let job = TranscriptionJob(transcriber: fake)
    let cues = try job.run(
      sources: .init(micURL: nil, systemURL: nil, embeddedURL: url("screen.mov")),
      progress: { _ in }, isCancelled: { false })

    XCTAssertEqual(fake.transcribedFiles, ["screen.mov"])
    XCTAssertEqual(cues.first?.source, .mic, "that backend never captured system audio")
  }

  func testSidecarsWinOverEmbeddedAudioWhenBothExist() throws {
    let fake = FakeTranscriber()
    let job = TranscriptionJob(transcriber: fake)
    _ = try job.run(
      sources: .init(micURL: url("mic.m4a"), systemURL: nil, embeddedURL: url("screen.mov")),
      progress: { _ in }, isCancelled: { false })
    XCTAssertEqual(fake.transcribedFiles, ["mic.m4a"], "never both")
  }

  func testNoAudioAtAllYieldsNoCuesRatherThanThrowing() throws {
    let job = TranscriptionJob(transcriber: FakeTranscriber())
    let cues = try job.run(
      sources: .init(micURL: nil, systemURL: nil, embeddedURL: nil),
      progress: { _ in }, isCancelled: { false })
    XCTAssertTrue(cues.isEmpty)
  }

  // MARK: - Progress and cancellation

  func testProgressIsMonotonicAndSpansBothSources() throws {
    let fake = FakeTranscriber()
    let job = TranscriptionJob(transcriber: fake)
    var seen: [Double] = []
    _ = try job.run(
      sources: .init(micURL: url("mic.m4a"), systemURL: url("system.m4a"), embeddedURL: nil),
      progress: { seen.append($0) }, isCancelled: { false })

    XCTAssertFalse(seen.isEmpty)
    for (a, b) in zip(seen, seen.dropFirst()) {
      XCTAssertLessThanOrEqual(a, b, "progress must never go backwards")
    }
    XCTAssertEqual(try XCTUnwrap(seen.last), 1.0, accuracy: 0.0001)
    XCTAssertTrue(
      seen.contains { $0 > 0.2 && $0 < 0.6 },
      "the first source should occupy the first half, not jump to 1.0")
  }

  func testCancellationStopsTheJobAndThrows() {
    let fake = FakeTranscriber()
    let job = TranscriptionJob(transcriber: fake)
    XCTAssertThrowsError(
      try job.run(
        sources: .init(micURL: url("mic.m4a"), systemURL: url("system.m4a"), embeddedURL: nil),
        progress: { _ in }, isCancelled: { true })
    ) { error in
      XCTAssertEqual(error as? TranscriptionError, .cancelled)
    }
  }

  func testAnUnavailableEngineThrowsItsReasonRatherThanReturningEmpty() {
    let fake = FakeTranscriber()
    fake.availability = .unavailable(reason: "appleSiliconRequired")
    let job = TranscriptionJob(transcriber: fake)
    XCTAssertThrowsError(
      try job.run(
        sources: .init(micURL: url("mic.m4a"), systemURL: nil, embeddedURL: nil),
        progress: { _ in }, isCancelled: { false })
    ) { error in
      XCTAssertEqual(
        error as? TranscriptionError, .unavailable(reason: "appleSiliconRequired"),
        "an empty transcript and an unsupported Mac must not look the same")
    }
  }

  // MARK: - Similarity

  func testSimilarityIgnoresCaseAndPunctuation() {
    XCTAssertEqual(
      TranscriptionJob.similarity("Hello, world!", "hello world"), 1.0, accuracy: 0.001)
  }

  func testSimilarityIsLowForUnrelatedText() {
    XCTAssertLessThan(
      TranscriptionJob.similarity("the quick brown fox", "entirely unrelated words"), 0.3)
  }
}
