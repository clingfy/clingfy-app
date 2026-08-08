import WhisperKit
import XCTest

@testable import Clingfy

/// The WhisperKit adapter's pure parts: decoding options and text mapping.
///
/// No model is loaded here. What is pinned is the set of engine defaults this
/// app must override — that list has now grown twice from real-run damage, and
/// each entry is a default that is wrong for a captioning product rather than a
/// preference.
final class WhisperKitTranscriberTests: XCTestCase {

  // MARK: - Special tokens

  /// The bug this exists for, from a first real run: cues came back reading
  /// `<|startoftranscript|><|en|><|transcribe|><|0.00|> And I was ...`.
  ///
  /// `SegmentSeeker` builds segment text from
  /// `skipSpecialTokens ? wordTokens : decodingResult.tokens`, and WhisperKit
  /// ships that flag OFF — so the control tokens were decoded straight into the
  /// caption, on their way to being burned into the video and written to .srt.
  func testDecodingSkipsSpecialTokens() {
    let options = WhisperKitTranscriber.decodingOptions(from: .default)
    XCTAssertTrue(
      options.skipSpecialTokens,
      "off by default, and the default puts control tokens in the subtitle")
  }

  func testControlTokensAreStrippedFromCueText() {
    XCTAssertEqual(
      WhisperKitTranscriber.stripSpecialTokens(
        "<|startoftranscript|><|en|><|transcribe|><|0.00|> And I was there"),
      "And I was there")
  }

  func testTimestampTokensAreStripped() {
    XCTAssertEqual(
      WhisperKitTranscriber.stripSpecialTokens(
        "<|2.26|> If you don't do this now, you might never do it.<|4.50|>"),
      "If you don't do this now, you might never do it.")
  }

  /// The strip must not eat the sentence around the tokens, and must not weld
  /// two words together where a token used to separate them.
  func testStrippingLeavesTheSentenceIntact() {
    XCTAssertEqual(
      WhisperKitTranscriber.stripSpecialTokens("one<|1.00|>two"), "one two")
    XCTAssertEqual(
      WhisperKitTranscriber.stripSpecialTokens("  spaced   out  "), "spaced out")
  }

  func testCleanTextIsUnchanged() {
    XCTAssertEqual(
      WhisperKitTranscriber.stripSpecialTokens("we gotta do it."), "we gotta do it.")
  }

  /// Angle brackets that are not control tokens are ordinary speech and must
  /// survive — a transcript can legitimately contain "less than" markup.
  func testOrdinaryAngleBracketsSurvive() {
    XCTAssertEqual(
      WhisperKitTranscriber.stripSpecialTokens("use <div> for that"),
      "use <div> for that")
  }

  func testASegmentOfNothingButTokensBecomesEmpty() {
    // Dropped downstream by the guards rather than written as a blank cue.
    XCTAssertEqual(
      WhisperKitTranscriber.stripSpecialTokens("<|startoftranscript|><|nospeech|>"), "")
  }

  // MARK: - map()

  /// The strip has to be wired INTO the mapping, not merely available. Testing
  /// the helper alone let a mutation that removed the call from `map` pass.
  func testMapStripsTokensFromTheCueItProduces() {
    let mapped = WhisperKitTranscriber.map([
      TranscriptionSegment(
        start: 2.0,
        end: 3.5,
        text: "<|startoftranscript|><|en|><|transcribe|><|0.00|> And I was there",
        words: [
          WordTiming(word: "<|0.00|> And", tokens: [], start: 2.0, end: 2.3, probability: 1),
          WordTiming(word: " there", tokens: [], start: 3.0, end: 3.5, probability: 1),
        ])
    ])

    XCTAssertEqual(mapped.first?.text, "And I was there")
    XCTAssertEqual(
      mapped.first?.words.first?.text, "And",
      "word text reaches the sidecar and the reflow rule, so it needs stripping too")
    XCTAssertEqual(mapped.first?.startMs, 2000)
    XCTAssertEqual(mapped.first?.endMs, 3500)
  }

  func testMapCarriesNoSpeechProbabilityForTheGuards() {
    let mapped = WhisperKitTranscriber.map([
      TranscriptionSegment(start: 0, end: 1, text: "hello", noSpeechProb: 0.73)
    ])
    XCTAssertEqual(mapped.first?.noSpeechProbability ?? 0, 0.73, accuracy: 0.0001)
  }

  // MARK: - The other overridden defaults

  /// Each of these is a WhisperKit default that is wrong for this product. They
  /// are asserted together because the failure mode is identical and silent:
  /// the engine changes a default, and captions quietly get worse.
  func testEngineDefaultsThisAppMustOverride() {
    let options = WhisperKitTranscriber.decodingOptions(from: .default)

    XCTAssertTrue(options.suppressBlank, "WhisperKit ships false; upstream whisper is true")
    XCTAssertTrue(options.wordTimestamps, "cut-reflow needs word timings")
    XCTAssertEqual(
      options.chunkingStrategy, .vad,
      "a screen recording is mostly silence, and VAD is the biggest lever against hallucinating over it")
    XCTAssertEqual(
      options.concurrentWorkerCount, 4,
      "defaults to 16 on macOS, which is 16x the per-window working set in an app already holding video buffers")
    XCTAssertEqual(options.task, .transcribe)
  }

  func testLanguageIsPassedThrough() {
    var options = TranscriptionOptions.default
    options.language = "en"
    XCTAssertEqual(WhisperKitTranscriber.decodingOptions(from: options).language, "en")

    options.language = nil
    XCTAssertNil(
      WhisperKitTranscriber.decodingOptions(from: options).language,
      "nil means auto-detect, not a missing value to substitute")
  }
}
