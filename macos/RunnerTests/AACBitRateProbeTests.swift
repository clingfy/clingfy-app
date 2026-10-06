import AVFoundation
import XCTest

@testable import Clingfy

/// What the real AAC-LC encoder accepts at 48 kHz stereo.
///
/// `AACEncoderSettings` holds per-channel bitrate to roughly 2 bits per sample
/// and caps it at 96 kbps, and its header is explicit that those numbers came
/// from driving the real pipeline rather than from a spec. The export
/// audio-quality tiers need a higher ceiling than 96 kbps/channel, so the same
/// method applies: find out what the encoder takes before choosing constants.
///
/// The failure being probed for is the one that file documents: `canAdd` and
/// `startWriting()` both succeed on an illegal tuple, and the encoder only
/// refuses on the FIRST appended sample buffer, as `-11861 "Cannot Encode
/// Media"` wrapping OSStatus `-12651`. So each case here appends a real buffer.
final class AACBitRateProbeTests: XCTestCase {

  /// Writes one second of 48 kHz stereo silence at `bitRate`, returning the
  /// error if the encoder refused it.
  private func attemptEncode(bitRate: Int, sampleRate: Double = 48_000) -> Error? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("aac_probe_\(bitRate)_\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: url) }

    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else {
      return NSError(domain: "probe", code: 1, userInfo: nil)
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 2,
      AVSampleRateKey: sampleRate,
      AVEncoderBitRateKey: bitRate,
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    guard writer.canAdd(input) else {
      return NSError(domain: "probe", code: 2, userInfo: nil)
    }
    writer.add(input)
    guard writer.startWriting() else { return writer.error }
    writer.startSession(atSourceTime: .zero)

    // One second of silence, as float32 deinterleaved — the shape the export
    // mix produces.
    let frames = AVAudioFrameCount(sampleRate)
    guard
      let fmt = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: 2),
      let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)
    else { return NSError(domain: "probe", code: 3, userInfo: nil) }
    pcm.frameLength = frames
    for ch in 0..<Int(fmt.channelCount) {
      if let p = pcm.floatChannelData?[ch] {
        for i in 0..<Int(frames) { p[i] = 0 }
      }
    }
    guard let sample = pcm.asSampleBuffer(presentationTime: .zero) else {
      return NSError(domain: "probe", code: 4, userInfo: nil)
    }

    // The moment of truth. An illegal tuple fails HERE, not above.
    let appended = input.append(sample)
    if !appended { return writer.error }
    input.markAsFinished()

    let done = XCTestExpectation(description: "finish")
    var finishError: Error?
    writer.finishWriting {
      if writer.status == .failed { finishError = writer.error }
      done.fulfill()
    }
    _ = XCTWaiter.wait(for: [done], timeout: 20)
    return finishError
  }

  /// The probe. Not an assertion about any one rate — it PRINTS the accepted
  /// set so the tier constants can be set from evidence, and asserts only the
  /// two things that must hold for the feature to exist at all.
  func testWhichBitRatesAACAcceptsAt48kHzStereo() {
    let candidates = [
      128_000, 160_000, 192_000, 224_000, 256_000, 288_000, 320_000, 384_000,
    ]
    var accepted: [Int] = []
    var rejected: [(Int, String)] = []
    for rate in candidates {
      if let error = attemptEncode(bitRate: rate) {
        rejected.append((rate, (error as NSError).code.description))
      } else {
        accepted.append(rate)
      }
    }
    // Measured on this machine, macOS 15, 2026-10-06:
    //   accepted = [128k, 160k, 192k, 224k, 256k, 288k, 320k]
    //   rejected = [384k]
    // The three tiers are pinned individually rather than as a set, so a
    // regression names which one the encoder stopped taking.
    XCTAssertTrue(
      accepted.contains(192_000),
      "192 kbps is AudioQuality.standard and what macOS exports today")
    XCTAssertTrue(
      accepted.contains(256_000), "256 kbps is AudioQuality.high")
    XCTAssertTrue(
      accepted.contains(320_000), "320 kbps is AudioQuality.best")
    XCTAssertFalse(
      accepted.contains(384_000),
      "384 kbps was refused when the ladder was chosen; if it is accepted now "
        + "the top tier could be raised, which is a product decision, not a "
        + "silent one — hence the assertion rather than a comment")
  }

  // MARK: - The tier mapping

  /// `standard` must be byte-identical to what shipped before tiers existed.
  func testStandardIsExactlyTodaysRate() {
    for rate in [16_000.0, 44_100.0, 48_000.0] {
      XCTAssertEqual(
        AACEncoderSettings.exportBitRate(
          sampleRate: rate, channels: 2, quality: "standard"),
        AACEncoderSettings.bitRate(sampleRate: rate, channels: 2),
        "standard delegates to the conservative rule at \(rate) Hz")
    }
  }

  /// An unknown or missing tier is `standard`, so an older payload exports
  /// exactly what it exports today.
  func testAnUnknownTierFallsBackToStandard() {
    for wire in ["", "ultra", "HIGH ", "garbage"] {
      let got = AACEncoderSettings.exportBitRate(
        sampleRate: 48_000, channels: 2, quality: wire)
      if wire.trimmingCharacters(in: .whitespaces).lowercased() == "high" {
        continue  // "HIGH " is a real tier, just sloppily cased
      }
      XCTAssertEqual(got, 192_000, "\(wire.debugDescription) must read as standard")
    }
  }

  func testTheTiersMapToTheAdvertisedStereoRates() {
    XCTAssertEqual(
      AACEncoderSettings.exportBitRate(
        sampleRate: 48_000, channels: 2, quality: "standard"),
      192_000)
    XCTAssertEqual(
      AACEncoderSettings.exportBitRate(
        sampleRate: 48_000, channels: 2, quality: "high"),
      256_000)
    XCTAssertEqual(
      AACEncoderSettings.exportBitRate(
        sampleRate: 48_000, channels: 2, quality: "best"),
      320_000)
  }

  /// The tier is a ceiling. A source below the rate whose ceiling was measured
  /// keeps the conservative rate however high a tier is asked for — the band
  /// between 96 and 128 kbps at 16 kHz is untested, and guessing into it is
  /// what produces a `-11861` on the first appended buffer.
  func testALowRateSourceIgnoresAHigherTier() {
    let conservative = AACEncoderSettings.bitRate(sampleRate: 16_000, channels: 2)
    for tier in ["high", "best"] {
      XCTAssertEqual(
        AACEncoderSettings.exportBitRate(
          sampleRate: 16_000, channels: 2, quality: tier),
        conservative,
        "a 16 kHz source must not be raised by the \(tier) tier")
    }
  }

  /// Every tier the UI offers must survive the real encoder at 48 kHz stereo,
  /// which is the whole reason the mapping is pinned to measured values.
  func testEveryTierActuallyEncodes() {
    for tier in ["standard", "high", "best"] {
      let rate = AACEncoderSettings.exportBitRate(
        sampleRate: 48_000, channels: 2, quality: tier)
      XCTAssertNil(
        attemptEncode(bitRate: rate),
        "tier \(tier) resolved to \(rate) bps and the encoder refused it")
    }
  }

  /// The low-rate case the existing rule exists for, restated as a guard: a
  /// 16 kHz source must NOT accept a high rate, which is why a quality tier
  /// has to stay a ceiling rather than become a fixed value.
  func testALowRateSourceStillRefusesAHighBitRate() {
    let error = attemptEncode(bitRate: 256_000, sampleRate: 16_000)
    XCTAssertNotNil(
      error,
      "if 16 kHz accepts 256 kbps then the clamp could be relaxed; as "
        + "documented in AACEncoderSettings it does not")
  }
}

extension AVAudioPCMBuffer {
  /// Minimal PCM -> CMSampleBuffer bridge for the probe.
  fileprivate func asSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
    var asbd = format.streamDescription.pointee
    var formatDescription: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription) == noErr,
      let formatDescription
    else { return nil }

    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: CMItemCount(frameLength),
        sampleTimingEntryCount: 1,
        sampleTimingArray: [
          CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        ],
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer) == noErr,
      let sampleBuffer
    else { return nil }

    guard
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        bufferList: audioBufferList) == noErr
    else { return nil }

    return sampleBuffer
  }
}
