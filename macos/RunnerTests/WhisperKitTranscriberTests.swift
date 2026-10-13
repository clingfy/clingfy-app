import AVFoundation
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

  // MARK: - Cancelling during the decode

  /// Decoding runs FIRST, before the model is even looked for, so it is the
  /// likeliest moment for a user to press Stop — and the decoder throws its own
  /// `CaptionAudioDecoder.DecodeError`, which is not a `TranscriptionError`.
  ///
  /// This protocol is documented to throw `TranscriptionError.cancelled`, and
  /// three layers above it tell a cancel from a failure by casting to that type.
  /// Letting the decoder's own error through failed all three: the service
  /// logged an error to Sentry, the bridge answered `CAPTIONS_FAILED`, and the
  /// user who had just pressed Stop was told "Couldn't generate subtitles".
  ///
  /// No model is involved — the throw happens before the engine queue is even
  /// entered — so this runs in milliseconds against a real .m4a.
  func testStoppingDuringTheDecodeThrowsCancelledAndNotTheDecodersOwnError() throws {
    let root = try temporaryDirectory()
    let audio = try writeTone(in: root, named: "mic.m4a", seconds: 1.0)
    let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)

    XCTAssertThrowsError(
      try transcriber.transcribe(
        url: audio, options: .default, progress: { _ in }, isCancelled: { true })
    ) { error in
      XCTAssertEqual(
        error as? TranscriptionError, .cancelled,
        "got \(error) — a deliberate Stop must not reach the bridge as a failure")
    }
  }

  /// The same seam, for a source that cannot be decoded at all. A foreign error
  /// type crossing here reaches the bridge as `String(describing:)` of something
  /// no layer above was written to read.
  func testAnUndecodableSourceThrowsInTheTranscriberTaxonomy() throws {
    let root = try temporaryDirectory()
    let missing = root.appendingPathComponent("gone.m4a")
    let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)

    XCTAssertThrowsError(
      try transcriber.transcribe(
        url: missing, options: .default, progress: { _ in }, isCancelled: { false })
    ) { error in
      XCTAssertEqual(error as? TranscriptionError, .noAudioTrack(missing), "got \(error)")
    }
  }

  // MARK: - The engine claim a cancelled job leaves behind

  /// One cancel used to disable "Delete speech model" for the whole session.
  ///
  /// The claim a cancelled job leaves on the engine has to release ITSELF:
  /// nothing else observes that task. The cancelling job throws immediately —
  /// deliberately, since the download it abandons is not interruptible — so the
  /// clear on the success path is never reached, and the only other one runs
  /// inside a LATER job. Cancel once and never transcribe again, and
  /// `isEngineBusy` stayed true forever: Settings › Storage refused to free the
  /// ~730 MB and said the model was in use with nothing running.
  func testAnAbandonedEngineTaskStopsCountingAsBusyOnceItFinishes() {
    let queue = DispatchQueue(label: "com.clingfy.test.drain")
    let drain = EngineDrain(queue: queue)
    let flag = TestFlag()
    let work = Task { await flag.waitUntilSet() }

    queue.sync { drain.claim(work) }
    XCTAssertTrue(drain.isDraining, "the abandoned task still owns the engine")

    flag.set()
    XCTAssertTrue(
      waitUntil { !drain.isDraining },
      "the claim outlived the task holding it, so nothing can ever delete the model")
  }

  /// A claim that finishes late must not release a claim made after it, or the
  /// delete path would be told the engine is free while a second abandoned
  /// download is still writing into the model directory.
  func testALateDrainDoesNotReleaseANewerClaim() {
    let queue = DispatchQueue(label: "com.clingfy.test.drain")
    let drain = EngineDrain(queue: queue)
    let firstFlag = TestFlag()
    let secondFlag = TestFlag()
    let first = Task { await firstFlag.waitUntilSet() }
    let second = Task { await secondFlag.waitUntilSet() }

    queue.sync { drain.claim(first) }
    queue.sync { drain.claim(second) }

    firstFlag.set()
    // Long enough for the stale release to land if it is going to.
    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertTrue(drain.isDraining, "the second abandoned task still owns the engine")

    secondFlag.set()
    XCTAssertTrue(waitUntil { !drain.isDraining })
  }

  /// Lets a `Task` be held open without blocking a cooperative thread, which is
  /// the trap when a test wants a long-running task it can end on cue.
  private final class TestFlag {
    private let lock = NSLock()
    private var value = false

    func set() {
      lock.lock()
      value = true
      lock.unlock()
    }

    var isSet: Bool {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func waitUntilSet() async {
      while !isSet {
        try? await Task.sleep(nanoseconds: 5_000_000)
      }
    }
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
  }

  // MARK: - Fixtures

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_whisper_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  /// A real compressed .m4a, because the decode being cancelled has to be a real
  /// decode: the cancel is checked between sample buffers, and a file with
  /// nothing to read never reaches that check.
  private func writeTone(
    in directory: URL, named name: String, seconds: Double, sampleRate: Double = 44_100
  ) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let writer = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
      ])
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    if let data = buffer.floatChannelData?[0] {
      for frame in 0..<Int(frames) {
        data[frame] = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate) * 0.5)
      }
    }
    try writer.write(from: buffer)
    return url
  }

  // MARK: - Not re-downloading what is already here

  /// What a FINISHED download leaves in the variant folder, verified against a
  /// real install (`.../whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB`)
  /// and against `WhisperKit.loadModels`, which resolves exactly these three
  /// bundles by name and throws if any is missing.
  private static let completeInstall = [
    "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
  ]

  /// Lays out a variant folder containing `bundles` (and optionally the
  /// `config.json` the same snapshot fetches).
  private func installModel(
    _ bundles: [String], config: Bool = true, for transcriber: WhisperKitTranscriber
  ) throws {
    let folder = transcriber.localModelFolder
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for bundle in bundles {
      try fm.createDirectory(
        at: folder.appendingPathComponent(bundle), withIntermediateDirectories: true)
    }
    if config {
      try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    }
  }

  /// Found in real testing: every press of Generate showed "Downloading speech
  /// model", even with the 600 MB already on disk.
  ///
  /// The cause was two changes meeting. The pipeline is cached in `pipe` and
  /// `loadedPipeline` returns early on it; a well-meant "release the model when
  /// the job ends" nil'd that cache after every run, so the next run fell
  /// through to `WhisperKit.download` — which reaches the network even on a warm
  /// cache and is what puts the download stage on screen. Offline, it failed
  /// outright with the model sitting right there.
  func testAModelAlreadyOnDiskIsNotFetchedAgain() throws {
    let root = try temporaryDirectory()
    let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)
    XCTAssertNil(
      transcriber.existingModelFolder(),
      "nothing on disk yet, so the download must run")

    try installModel(Self.completeInstall, for: transcriber)

    XCTAssertEqual(
      transcriber.existingModelFolder(), transcriber.localModelFolder,
      "a complete model on disk must be used as-is, with no download stage")
  }

  /// An `.mlpackage` install is the other shape `loadModels` accepts —
  /// `ModelUtilities.detectModelURL` falls back to
  /// `<name>.mlpackage/Data/com.apple.CoreML/model.mlmodel` — so requiring
  /// `.mlmodelc` literally would send a working install back to the network.
  func testAnUncompiledPackageInstallAlsoCounts() throws {
    let root = try temporaryDirectory()
    let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)
    let folder = transcriber.localModelFolder
    for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
      let payload = folder
        .appendingPathComponent("\(name).mlpackage")
        .appendingPathComponent("Data/com.apple.CoreML")
      try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
      try Data("model".utf8).write(to: payload.appendingPathComponent("model.mlmodel"))
    }
    try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))

    XCTAssertEqual(transcriber.existingModelFolder(), folder)
  }

  /// An interrupted download leaves the directory behind. Treating that as
  /// installed would skip the fetch meant to repair it, and the load would fail
  /// on missing weights with no way back.
  func testAnEmptyFolderFromAnInterruptedDownloadDoesNotCountAsInstalled() throws {
    let root = try temporaryDirectory()
    let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)
    try FileManager.default.createDirectory(
      at: transcriber.localModelFolder, withIntermediateDirectories: true)

    XCTAssertNil(
      transcriber.existingModelFolder(),
      "a folder with no bundles at all is a half-finished download, not a model")
  }

  /// The bug this is really for: a download interrupted PART WAY, which is what
  /// a Stop or a dropped connection actually produces.
  ///
  /// `HubApi.snapshot` writes the files one at a time, so the realistic wreckage
  /// is one or two bundles present and the rest missing. Judging installation on
  /// "contains something ending in .mlmodelc" called that a model: the repair
  /// download was skipped, the config was built with `download: false`, and
  /// `loadModels` threw on the bundle that never arrived — on every subsequent
  /// Generate, for the life of the install, with no way back from the UI.
  func testAPartlyDownloadedModelDoesNotCountAsInstalled() throws {
    for present in [
      ["AudioEncoder.mlmodelc"],
      ["MelSpectrogram.mlmodelc"],
      ["TextDecoder.mlmodelc"],
      ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"],
    ] {
      let root = try temporaryDirectory()
      let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)
      try installModel(present, for: transcriber)

      XCTAssertNil(
        transcriber.existingModelFolder(),
        "\(present) is a half-finished download; the repair fetch must still run")
    }
  }

  /// The metadata comes down in the same snapshot as the weights, so a variant
  /// folder without it is a download that stopped before the end.
  func testAllTheBundlesWithoutTheConfigIsStillAnUnfinishedDownload() throws {
    let root = try temporaryDirectory()
    let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)
    try installModel(Self.completeInstall, config: false, for: transcriber)

    XCTAssertNil(transcriber.existingModelFolder())
  }

  // MARK: - Handing the weights back

  /// `releaseModel` has to say whether it actually released.
  ///
  /// It skips while a cancelled job's abandoned task owns the engine — that task
  /// may be inside `WhisperKit(config)` and about to assign into `pipe`, so
  /// taking the pipeline away underneath is the race this file's header forbids.
  /// The skip used to return exactly what a real unload returned: nothing. The
  /// caller that matters is `deleteCaptionModel`, which removed ~730 MB on the
  /// strength of this call having been made, so a skip deleted weights that were
  /// never unloaded — with an uninterruptible download still writing into the
  /// same directory.
  func testReleasingIsRefusedWhileACancelledJobStillOwnsTheEngine() async throws {
    let root = try temporaryDirectory()
    let transcriber = WhisperKitTranscriber(model: "test-variant", modelDirectory: root)

    let idle = await transcriber.releaseModel()
    XCTAssertTrue(idle, "with nothing running there is nothing to refuse")

    let flag = TestFlag()
    transcriber.claimEngineForTesting(Task { await flag.waitUntilSet() })

    let duringDrain = await transcriber.releaseModel()
    XCTAssertFalse(
      duringDrain,
      "the engine kept the weights, so the caller must not be told they were freed")

    flag.set()
    XCTAssertTrue(waitUntil { !transcriber.drain.isDraining })
    let afterDrain = await transcriber.releaseModel()
    XCTAssertTrue(afterDrain, "and once the abandoned task is gone, releasing works again")
  }

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
  /// The picker is built from this list, so an empty or inverted one is a
  /// feature that silently offers nothing or offers nonsense.
  func testSupportedLanguagesComeFromTheEngineAndAreCodeKeyed() throws {
    let languages = WhisperKitTranscriber.supportedLanguages

    XCTAssertGreaterThan(
      languages.count, 50,
      "the engine publishes ~99 languages; a short list means the constant "
        + "moved and this is reading something else")

    // Codes and names are easy to swap, and the swap is invisible until a user
    // opens the picker and sees two-letter codes -- or worse, until a decode is
    // forced with "english" as the language.
    let english = try XCTUnwrap(
      languages.first { $0.name == "english" },
      "no entry named 'english' -- the engine's keys are names, not codes")
    XCTAssertEqual(english.code, "en")

    let arabic = try XCTUnwrap(languages.first { $0.name == "arabic" })
    XCTAssertEqual(arabic.code, "ar")

    XCTAssertEqual(
      languages.map(\.name), languages.map(\.name).sorted(),
      "sorted by name, because the UI presents them in this order")
  }

  // MARK: - The runtime engine swap (§A.7.1)
  //
  // The swap itself loads real Core ML models, so it cannot run here; it is
  // exercised end to end in the running app. What CAN be pinned without a model
  // is every rule the swap depends on — and each of these is a rule whose
  // violation would be silent: the wrong model transcribing and reporting
  // success, a variant string walking out of the models folder, or hundreds of
  // megabytes of dead `_turbo` weight downloaded on a picker bug.

  /// The fast path used to be `if let pipe { return pipe }`, which handed a job
  /// whatever was loaded. A job naming a DIFFERENT variant must not reuse it.
  func testTheResidentPipelineIsReusedOnlyForTheSameVariant() {
    XCTAssertTrue(
      WhisperKitTranscriber.canReuseResident(
        residentVariant: "openai_whisper-tiny", requested: "openai_whisper-tiny"))
    XCTAssertFalse(
      WhisperKitTranscriber.canReuseResident(
        residentVariant: "openai_whisper-tiny",
        requested: "openai_whisper-large-v3-v20240930_626MB"),
      "a different variant must load its own model, not run on the resident one")
    XCTAssertFalse(
      WhisperKitTranscriber.canReuseResident(
        residentVariant: nil, requested: "openai_whisper-tiny"),
      "nothing resident means nothing to reuse")
  }

  /// Several variants coexist on disk because the variant is the folder's LEAF.
  func testEachVariantGetsItsOwnFolder() throws {
    let root = try temporaryDirectory()
    let transcriber = WhisperKitTranscriber(model: "openai_whisper-tiny", modelDirectory: root)
    let tiny = transcriber.modelFolder(for: "openai_whisper-tiny")
    let large = transcriber.modelFolder(for: "openai_whisper-large-v3-v20240930_626MB")

    XCTAssertNotEqual(tiny, large)
    XCTAssertEqual(tiny.deletingLastPathComponent(), large.deletingLastPathComponent(),
      "siblings under one whisperkit-coreml root")
    XCTAssertEqual(transcriber.localModelFolder, tiny,
      "the legacy accessor is the DEFAULT variant's folder")
  }

  /// Readiness is per variant: one model on disk says nothing about another.
  func testExistingModelFolderAnswersForTheVariantAsked() throws {
    let root = try temporaryDirectory()
    let transcriber = WhisperKitTranscriber(model: "openai_whisper-tiny", modelDirectory: root)
    let tinyFolder = transcriber.modelFolder(for: "openai_whisper-tiny")
    for bundle in CaptionModelStore.requiredModelBundles {
      let f = tinyFolder.appendingPathComponent("\(bundle).mlmodelc")
      try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
      try Data([1]).write(to: f.appendingPathComponent("w"))
    }
    try Data("{}".utf8).write(to: tinyFolder.appendingPathComponent("config.json"))

    XCTAssertEqual(transcriber.existingModelFolder(for: "openai_whisper-tiny"), tinyFolder)
    XCTAssertNil(
      transcriber.existingModelFolder(for: "openai_whisper-small_216MB"),
      "having tiny must not make small look installed — that is the readiness lie "
        + "that would skip a needed download")
  }

  // MARK: - Resolving a requested variant

  func testNilAndTheDefaultResolveToTheDefault() {
    XCTAssertEqual(CaptionsService.resolvedVariant(nil), WhisperKitTranscriber.defaultModel)
    XCTAssertEqual(
      CaptionsService.resolvedVariant(WhisperKitTranscriber.defaultModel),
      WhisperKitTranscriber.defaultModel)
    XCTAssertEqual(CaptionsService.modelVariant, WhisperKitTranscriber.defaultModel)
  }

  func testARealVariantIsHonoured() {
    for v in ["openai_whisper-tiny", "openai_whisper-small_216MB", "openai_whisper-base"] {
      XCTAssertEqual(CaptionsService.resolvedVariant(v), v)
    }
  }

  /// The variant becomes a path component. Anything that could walk out of the
  /// models tree falls back to the default instead of being trusted.
  func testAPathLikeVariantIsRefused() {
    for bad in [
      "../../etc", "openai_whisper-../x", "openai_whisper-a/b", "openai_whisper-a\\b",
      "/abs", "", "openai_whisper- spaced", "openai_whisper-ünïcode",
    ] {
      XCTAssertEqual(
        CaptionsService.resolvedVariant(bad), WhisperKitTranscriber.defaultModel,
        "\(bad.debugDescription) must not be used as a folder name")
    }
  }

  func testANonWhisperNameIsRefused() {
    XCTAssertEqual(
      CaptionsService.resolvedVariant("distil-whisper_distil-large-v3"),
      WhisperKitTranscriber.defaultModel)
  }

  /// In WhisperKit a `_turbo` SUFFIX is an extra context-prefill model, not
  /// OpenAI's turbo release, and it is dead weight. Eight of the twenty-three
  /// hub variants carry it, so the guard is not hypothetical.
  func testTheTurboSuffixIsRefusedButTheTurboReleaseIsNot() {
    for dead in [
      "openai_whisper-large-v3_turbo",
      "openai_whisper-large-v3_turbo_954MB",
      "openai_whisper-large-v3-v20240930_turbo",
      "openai_whisper-large-v3-v20240930_turbo_632MB",
    ] {
      XCTAssertEqual(
        CaptionsService.resolvedVariant(dead), WhisperKitTranscriber.defaultModel,
        "\(dead) is the context-prefill build and must not be downloaded")
    }
    // The real turbo RELEASE — the default — has no `_turbo` suffix at all.
    XCTAssertTrue(CaptionsService.isAcceptableVariant(WhisperKitTranscriber.defaultModel))
  }

  /// Every existing caller builds options without naming a model; that must
  /// still mean "the default", not an empty or garbage variant.
  func testOptionsNameNoModelByDefault() {
    XCTAssertNil(TranscriptionOptions.default.model)
    XCTAssertNil(TranscriptionOptions.strict.model)
  }
}


/// The hot swap, on the real engine with the real models: tiny, then large,
/// then tiny again, on ONE transcriber that is never released in between.
///
/// Production rarely reaches this branch, because `endRun` releases the model
/// after every job, so a swap is usually a cold load. That is exactly why it
/// needs a deliberate test: the code that unloads one pipeline and builds
/// another runs almost never, and a branch that runs almost never is where a
/// leaked pipeline or a stale `residentVariant` would live unnoticed.
///
/// Opt-in, and skipped without both models on disk. It loads two Core ML
/// models and can take minutes on a cold ANE cache, which is not something the
/// fast suite should pay for, and it never downloads (CI has no models):
///
///   TEST_RUNNER_CLINGFY_RUN_MODEL_SWAP=1 xcodebuild test ... \
///     -only-testing:RunnerTests/WhisperKitHotSwapTests
final class WhisperKitHotSwapTests: XCTestCase {

  private let tiny = "openai_whisper-tiny"
  private let large = WhisperKitTranscriber.defaultModel

  func testSwapsBetweenRealModelsWithoutReleasingInBetween() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["CLINGFY_RUN_MODEL_SWAP"] == "1",
      "opt-in: set TEST_RUNNER_CLINGFY_RUN_MODEL_SWAP=1")

    let modelsRoot = AppPaths.captionModelsDirectoryURLIfPresent()
    let transcriber = WhisperKitTranscriber(modelDirectory: modelsRoot)
    for variant in [tiny, large] {
      try XCTSkipIf(
        transcriber.existingModelFolder(for: variant) == nil,
        "\(variant) is not downloaded; generate subtitles with it once in the dev app")
    }
    let before = CaptionModelStore.installedVariants(
      root: CaptionModelStore.variantsRootURL()
    ).map(\.variant).sorted()

    let audio = try spokenSentence()
    defer { try? FileManager.default.removeItem(at: audio) }

    for variant in [tiny, large, tiny] {
      var options = TranscriptionOptions.default
      options.model = variant
      options.language = "en"
      let outcome = try transcriber.transcribe(
        url: audio, options: options, progress: { _ in }, isCancelled: { false })

      XCTAssertEqual(
        transcriber.residentModelVariant, variant,
        "after a job the resident pipeline is the one that job asked for")
      let text = outcome.segments.map(\.text).joined(separator: " ").lowercased()
      XCTAssertTrue(
        text.contains("fox"), "\(variant) produced \"\(text)\", not the spoken sentence")
    }

    XCTAssertEqual(
      CaptionModelStore.installedVariants(root: CaptionModelStore.variantsRootURL())
        .map(\.variant).sorted(),
      before,
      "a swap between two downloaded models must not download or remove anything")

    let released = expectation(description: "released")
    Task {
      _ = await transcriber.releaseModel()
      released.fulfill()
    }
    wait(for: [released], timeout: 30)
    XCTAssertNil(transcriber.residentModelVariant, "release clears the record with the pipeline")
  }

  /// A known sentence from the system voice, so the test needs no fixture.
  private func spokenSentence() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_swap_\(UUID().uuidString).aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "The quick brown fox jumps over the lazy dog."]
    try say.run()
    say.waitUntilExit()
    try XCTSkipIf(say.terminationStatus != 0, "the system voice is unavailable")
    return url
  }
}
